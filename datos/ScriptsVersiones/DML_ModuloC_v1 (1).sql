-- ============================================================
--  MÓDULO C: CUENTAS POR PAGAR
--  SECCIÓN 4 — SCRIPT DML: DATOS DE PRUEBA + TRIGGERS
--  ≥ 50 registros por tabla principal
--  Compatible con ScriptsModuloC_v7.sql (MySQL 8.x / InnoDB)
-- ============================================================

USE modulo_c;

-- ============================================================
-- A. TRIGGERS
-- ============================================================
-- Justificación de elección de triggers vs. SPs:
--   Los SPs del módulo implementan la lógica de negocio principal
--   mediante el patrón Observer. Los triggers complementan esa
--   lógica en tres escenarios que los SPs no pueden cubrir:
--   (1) Operaciones que llegan directamente al motor sin pasar por SP
--       (herramientas de administración, scripts de migración).
--   (2) Validaciones de integridad matemática que deben ser
--       absolutamente invariantes (total = base + iva).
--   (3) Registro automático de vencimientos detectados al leer
--       CuentaPorPagar fuera del flujo normal de pagos.
-- ============================================================

DELIMITER $$

-- ------------------------------------------------------------
-- trg_factura_before_insert
-- Propósito: Validar invariante financiera total = base_imponible + monto_iva
--            antes de persistir cualquier factura, independientemente
--            de si la inserción viene del SP o de una herramienta externa.
-- Justificación: Esta validación no puede depender exclusivamente del SP
--   porque los datos tributarios deben ser correctos a nivel de motor
--   (RNF04). Si se usa una herramienta de migración de datos o un
--   script de carga masiva, el trigger garantiza la integridad sin
--   requerir que el código de carga conozca las reglas del negocio.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_factura_before_insert$$
CREATE TRIGGER trg_factura_before_insert
BEFORE INSERT ON FacturaProveedor
FOR EACH ROW
BEGIN
    IF ABS(NEW.total - (NEW.base_imponible + NEW.monto_iva)) > 0.01 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'El total de la factura no coincide con base_imponible + monto_iva.';
    END IF;
END$$

-- ------------------------------------------------------------
-- trg_factura_before_update
-- Propósito: Mismo control que el trigger anterior pero al actualizar
--            una factura. Adicionalmente impide modificar una factura
--            anulada (estado final irreversible).
-- Justificación: La regla de estado final irreversible debe ser
--   enforced a nivel de motor para prevenir actualizaciones accidentales
--   mediante UPDATE directo en herramientas de administración.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_factura_before_update$$
CREATE TRIGGER trg_factura_before_update
BEFORE UPDATE ON FacturaProveedor
FOR EACH ROW
BEGIN
    IF OLD.estado = 'anulada' AND NEW.estado <> 'anulada' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No se puede reactivar una factura anulada.';
    END IF;
    IF ABS(NEW.total - (NEW.base_imponible + NEW.monto_iva)) > 0.01 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'El total de la factura no coincide con base_imponible + monto_iva.';
    END IF;
END$$

-- ------------------------------------------------------------
-- trg_pago_after_insert
-- Propósito: Actualizar saldo_pendiente y estado de CuentaPorPagar
--            como capa de seguridad extra cuando un pago se inserta
--            directamente (sin pasar por sp_registrar_pago).
--            Referenciado explícitamente en la Sección 3.4 del informe
--            como mecanismo de control de la desnormalización controlada.
-- Justificación: saldo_pendiente se almacena desnormalizado por
--   rendimiento (evita SUM() en cada consulta de saldo). El trigger
--   garantiza su consistencia incluso en operaciones directas al motor,
--   complementando el FOR UPDATE del SP para prevenir race conditions
--   en escenarios de mantenimiento administrativo.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_pago_after_insert$$
CREATE TRIGGER trg_pago_after_insert
AFTER INSERT ON PagoProveedor
FOR EACH ROW
BEGIN
    DECLARE v_saldo_actual  DECIMAL(12,2);
    DECLARE v_nuevo_saldo   DECIMAL(12,2);

    SELECT saldo_pendiente INTO v_saldo_actual
    FROM   CuentaPorPagar
    WHERE  id_cxp = NEW.id_cxp;

    SET v_nuevo_saldo = v_saldo_actual - NEW.monto;
    IF v_nuevo_saldo < 0 THEN SET v_nuevo_saldo = 0; END IF;

    UPDATE CuentaPorPagar
    SET    saldo_pendiente    = v_nuevo_saldo,
           estado             = CASE WHEN v_nuevo_saldo <= 0 THEN 'pagada' ELSE 'pagada_parcial' END,
           fecha_modificacion = NOW()
    WHERE  id_cxp = NEW.id_cxp;
END$$

-- ------------------------------------------------------------
-- trg_cxp_after_update_auditoria
-- Propósito: Registrar en BitacoraAuditoria cualquier cambio de estado
--            en CuentaPorPagar que no pase por sp_registrar_pago.
--            Captura actualizaciones administrativas (p. ej., corrección
--            de estado por un DBA o script de conciliación periódica).
-- Justificación: RNF04 exige registro de todas las operaciones financieras
--   sensibles. Los SPs ya insertan en BitacoraAuditoria, pero si un
--   administrador ejecuta un UPDATE directo el SP no se invoca.
--   El trigger cubre ese gap sin duplicar registros cuando el SP ya
--   auditó (las inserciones del SP ocurren dentro de la transacción
--   antes de que este trigger dispare; el trigger solo actúa en cambios
--   de estado no originados por el SP, que no modifica estado directamente
--   en CuentaPorPagar — lo hace a través del trigger trg_pago_after_insert).
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_cxp_after_update_auditoria$$
CREATE TRIGGER trg_cxp_after_update_auditoria
AFTER UPDATE ON CuentaPorPagar
FOR EACH ROW
BEGIN
    IF OLD.estado <> NEW.estado OR OLD.saldo_pendiente <> NEW.saldo_pendiente THEN
        INSERT INTO BitacoraAuditoria (
            tabla_afectada, operacion, id_registro, usuario,
            valor_anterior, valor_nuevo, fecha_evento
        ) VALUES (
            'CuentaPorPagar', 'UPDATE', NEW.id_cxp,
            COALESCE(NEW.usuario_modificacion, 'sistema'),
            JSON_OBJECT('estado', OLD.estado, 'saldo_pendiente', OLD.saldo_pendiente),
            JSON_OBJECT('estado', NEW.estado, 'saldo_pendiente', NEW.saldo_pendiente),
            NOW()
        );
    END IF;
END$$

DELIMITER ;

-- ============================================================
-- B. DATOS DE PRUEBA — DML
-- Orden de inserción respeta FK:
--   Proveedor → subtipos → OrdenCompra → DetalleOC
--   → Recepcion → DetalleRecepcion
--   → FacturaProveedor → CuentaPorPagar → PagoProveedor
-- ============================================================

-- ============================================================
-- B.1 Proveedor  (50 registros: 20 naturales + 30 jurídicas)
-- ============================================================
INSERT INTO Proveedor
(tipo_proveedor, identificacion, razon_social, email, telefono, direccion, dias_credito, cuenta_bancaria, banco, calificacion, activo, fecha_creacion, usuario_creacion)
VALUES
  ('persona_natural','1712345678','Luis Antonio Peralta Vera','luis.peralta@gmail.com','0991234567','Av. Mariscal Sucre 12-34, Quito',15,'22012000000','Banco Pichincha','A',1,'2024-01-01 08:00:00','admin'),
  ('persona_natural','1756789012','Carmen Rosa Delgado Ochoa','carmen.delgado@yahoo.es','0987654321','Calle Bolívar 45, Cuenca',30,'33002000001','Banco Guayaquil','B',1,'2024-01-02 08:00:00','admin'),
  ('persona_natural','0987654321','Jorge Fabián Mora Espinosa','jmora@hotmail.com','0998765432','Av. 10 de Agosto 123, Quito',45,'33002000002','Produbanco','C',1,'2024-01-03 08:00:00','admin'),
  ('persona_natural','1834567890','Sofía Isabel Andrade Lara','s.andrade@gmail.com','0976543210','Calle Gran Colombia 8, Loja',30,'33002000003','Banco del Pacífico','A',1,'2024-01-04 08:00:00','admin'),
  ('persona_natural','0712345678','Rodrigo Hernán Vásquez Paz','r.vasquez@outlook.com','0965432109','Av. Colón 56, Ambato',60,'33002000004','Banco Internacional','B',1,'2024-01-05 08:00:00','admin'),
  ('persona_natural','1745678901','Patricia Elena Ruiz Herrera','p.ruiz@live.com','0954321098','Calle Sucre 77, Riobamba',30,'33002000005','Banco Bolivariano','A',1,'2024-01-06 08:00:00','admin'),
  ('persona_natural','1823456789','Andrés Miguel Torres Salinas','a.torres@gmail.com','0943210987','Av. Atahualpa 222, Ibarra',15,'33002000006','Banco de Loja','C',1,'2024-01-07 08:00:00','admin'),
  ('persona_natural','0834567890','Verónica Marcela Castro Ríos','v.castro@yahoo.com','0932109876','Calle Pichincha 33, Machala',30,'33002000007','BanEcuador','B',1,'2024-01-08 08:00:00','admin'),
  ('persona_natural','1701234567','Felipe Sebastián León Cuesta','f.leon@gmail.com','0921098765','Av. Huayna Cápac 90, Cuenca',45,'33002000008','Banco del Austro','A',1,'2024-01-09 08:00:00','admin'),
  ('persona_natural','1789012345','Gloria María Jiménez Suárez','g.jimenez@hotmail.com','0910987654','Calle Loja 15, Azogues',30,'33002000009','Banco Procredit','A',1,'2024-01-10 08:00:00','admin'),
  ('persona_natural','0923456789','Hernán David Pinto Arroyo','h.pinto@gmail.com','0999876543','Av. República 44, Quito',60,'22012000010','Banco Pichincha','B',1,'2024-01-11 08:00:00','admin'),
  ('persona_natural','1867890123','Lucía Fernanda Quishpe Toapanta','l.quishpe@outlook.com','0988765432','Calle Guayaquil 101, Latacunga',30,'33002000011','Produbanco','C',1,'2024-01-12 08:00:00','admin'),
  ('persona_natural','0756789012','Marcos Esteban Romero Navas','m.romero@live.com','0977654321','Av. Rodrigo de Chávez, Guaranda',15,'33002000012','Banco Guayaquil','A',1,'2024-01-13 08:00:00','admin'),
  ('persona_natural','1745012345','Elena Susana Flores Guerrero','e.flores@gmail.com','0966543210','Calle Simón Bolívar 8, Tulcán',45,'33002000013','Banco del Pacífico','B',1,'2024-01-14 08:00:00','admin'),
  ('persona_natural','1801234567','Pablo Alejandro Benítez Mora','p.benitez@yahoo.es','0955432109','Av. 6 de Diciembre 300, Quito',30,'33002000014','Banco Internacional','A',1,'2024-01-15 08:00:00','admin'),
  ('persona_natural','0867890123','Rosa Inés Medina Alvarado','r.medina@gmail.com','0944321098','Calle Olmedo 12, Esmeraldas',30,'33002000015','Banco Bolivariano','C',1,'2024-01-16 08:00:00','admin'),
  ('persona_natural','1778901234','Gonzalo Ramiro Ortega Villacís','g.ortega@hotmail.com','0933210987','Av. Quito 456, Santo Domingo',60,'33002000016','Banco Austro','B',1,'2024-01-17 08:00:00','admin'),
  ('persona_natural','0745678901','Natalia Alejandra Paredes Cruz','n.paredes@gmail.com','0922109876','Calle Chimborazo 67, Riobamba',15,'22012000017','Banco Pichincha','A',1,'2024-01-18 08:00:00','admin'),
  ('persona_natural','1856789012','Miguel Ángel Cárdenas Ponce','m.cardenas@outlook.com','0911098765','Av. Los Shyris 890, Quito',30,'33002000018','Produbanco','B',1,'2024-01-19 08:00:00','admin'),
  ('persona_natural','0823456789','Ana Cecilia Quispe Lema','a.quispe@gmail.com','0900987654','Calle Sucre 234, Otavalo',30,'33002000019','BanEcuador','A',1,'2024-01-20 08:00:00','admin'),
  ('persona_juridica','1790012345001','DISTRIMAYORISTA CENTRAL S.A.','compras@distrimayorista.ec','022000000','Av. Amazonas 123, Quito',30,'22013000000','Banco Pichincha','A',1,'2023-01-01 09:00:00','admin'),
  ('persona_juridica','1790023456001','IMPORTACIONES ANDINA CIA. LTDA.','compras@importaciones.ec','022000001','Km 5 Vía a Daule, Guayaquil',45,'33003000001','Banco Guayaquil','A',1,'2023-02-02 09:00:00','admin'),
  ('persona_juridica','0990034567001','SUMINISTROS TECNOLÓGICOS DEL NORTE S.A.','compras@suministros.ec','022000002','Av. Universitaria 45, Cuenca',60,'33003000002','Produbanco','B',1,'2023-03-03 09:00:00','admin'),
  ('persona_juridica','1790045678001','ALIMENTOS Y BEBIDAS ECUATORIANAS S.A.','compras@alimentos.ec','022000003','Calle Primera 12, Ambato',30,'33003000003','Banco del Pacífico','A',1,'2023-04-04 09:00:00','admin'),
  ('persona_juridica','0990056789001','FERRETERÍA INDUSTRIAL GLOBAL CIA. LTDA.','compras@ferretería.ec','022000004','Av. Quito 789, Riobamba',30,'33003000004','Banco Internacional','B',1,'2023-05-05 09:00:00','admin'),
  ('persona_juridica','1790067890001','PAPELERÍA Y ÚTILES ESCOLARES S.A.','compras@papelería.ec','022000005','Calle Bolívar 34, Loja',15,'33003000005','Banco Bolivariano','C',1,'2023-06-06 09:00:00','admin'),
  ('persona_juridica','0990078901001','MUEBLES Y DECORACIÓN MODERNA S.A.','compras@muebles.ec','022000006','Av. Eloy Alfaro 56, Quito',45,'33003000006','Banco de Loja','A',1,'2023-07-07 09:00:00','admin'),
  ('persona_juridica','1790089012001','SERVICIOS LOGÍSTICOS RÁPIDOS CIA. LTDA.','compras@servicios.ec','022000007','Av. Del Ejército 90, Guayaquil',30,'33003000007','BanEcuador','B',1,'2023-08-08 09:00:00','admin'),
  ('persona_juridica','0990090123001','MATERIALES DE CONSTRUCCIÓN CENTRO S.A.','compras@materiales.ec','022000008','Calle Olmedo 23, Machala',60,'33003000008','Banco del Austro','A',1,'2023-09-09 09:00:00','admin'),
  ('persona_juridica','1790101234001','QUÍMICOS Y SOLVENTES INDUSTRIALES S.A.','compras@químicos.ec','022000009','Av. Las Palmas 67, Esmeraldas',30,'33003000009','Banco Procredit','A',1,'2023-10-10 09:00:00','admin'),
  ('persona_juridica','0990112345001','ELECTRODOMÉSTICOS DEL PACÍFICO S.A.','compras@electrodomésticos.ec','022000010','Av. Maldonado 345, Quito',45,'22013000010','Banco Pichincha','B',1,'2023-11-11 09:00:00','admin'),
  ('persona_juridica','1790123456001','TEXTILES NACIONALES CIA. LTDA.','compras@textiles.ec','022000011','Km 2 Vía Manta, Portoviejo',30,'33003000011','Produbanco','A',1,'2023-12-12 09:00:00','admin'),
  ('persona_juridica','0990134567001','PRODUCTOS FARMACÉUTICOS ANDES S.A.','compras@productos.ec','022000012','Av. Del Maestro 78, Ibarra',30,'33003000012','Banco Guayaquil','C',1,'2023-01-13 09:00:00','admin'),
  ('persona_juridica','1790145678001','AGROQUÍMICOS Y FERTILIZANTES S.A.','compras@agroquímicos.ec','022000013','Calle García Moreno 12, Tulcán',60,'33003000013','Banco del Pacífico','B',1,'2023-02-14 09:00:00','admin'),
  ('persona_juridica','0990156789001','REPUESTOS AUTOMOTRICES DEL SUR S.A.','compras@repuestos.ec','022000014','Av. Colón 456, Ambato',15,'33003000014','Banco Internacional','A',1,'2023-03-15 09:00:00','admin'),
  ('persona_juridica','1790167890001','CLIMATIZACIÓN Y REFRIGERACIÓN S.A.','compras@climatización.ec','022000015','Av. Guayas 89, Guayaquil',45,'33003000015','Banco Bolivariano','A',1,'2023-04-16 09:00:00','admin'),
  ('persona_juridica','0990178901001','CALZADO Y ARTÍCULOS DE CUERO CIA. LTDA.','compras@calzado.ec','022000016','Calle Sucre 23, Otavalo',30,'33003000016','Banco Austro','B',1,'2023-05-17 09:00:00','admin'),
  ('persona_juridica','1790189012001','SISTEMAS INFORMÁTICOS AVANZADOS S.A.','compras@sistemas.ec','022000017','Av. 24 de Mayo 567, Quito',30,'22013000017','Banco Pichincha','A',1,'2023-06-18 09:00:00','admin'),
  ('persona_juridica','0990190123001','COMBUSTIBLES Y LUBRICANTES S.A.','compras@combustibles.ec','022000018','Km 3 Vía a Baños, Ambato',45,'33003000018','Produbanco','B',1,'2023-07-19 09:00:00','admin'),
  ('persona_juridica','1790201234001','PUBLICIDAD Y DISEÑO INTEGRAL CIA. LTDA.','compras@publicidad.ec','022000019','Calle Chimborazo 34, Riobamba',60,'33003000019','BanEcuador','C',1,'2023-08-20 09:00:00','admin'),
  ('persona_juridica','0990212345001','EQUIPOS MÉDICOS Y HOSPITALARIOS S.A.','compras@equipos.ec','022000020','Av. Plaza Dañín 12, Guayaquil',30,'22013000020','Banco Pichincha','A',1,'2023-09-21 09:00:00','admin'),
  ('persona_juridica','1790223456001','CONFECCIONES TEXTILES NACIONALES S.A.','compras@confecciones.ec','022000021','Calle Rocafuerte 56, Latacunga',30,'33003000021','Banco Guayaquil','B',1,'2023-10-22 09:00:00','admin'),
  ('persona_juridica','0990234567001','PLÁSTICOS Y EMPAQUES INDUSTRIALES S.A.','compras@plásticos.ec','022000022','Av. Patria 789, Quito',45,'33003000022','Produbanco','A',1,'2023-11-23 09:00:00','admin'),
  ('persona_juridica','1790245678001','ELECTRÓNICA DE CONSUMO S.A.','compras@electrónica.ec','022000023','Km 4 Vía al Lago, Tulcán',30,'33003000023','Banco del Pacífico','A',1,'2023-12-24 09:00:00','admin'),
  ('persona_juridica','0990256789001','PRODUCTOS DE LIMPIEZA HOGAR CIA. LTDA.','compras@productos.ec','022000024','Calle Manuela Cañizares 23, Cuenca',15,'33003000024','Banco Internacional','B',1,'2023-01-25 09:00:00','admin'),
  ('persona_juridica','1790267890001','MAQUINARIA AGRÍCOLA Y PECUARIA S.A.','compras@maquinaria.ec','022000025','Av. 10 de Agosto 90, Ibarra',60,'33003000025','Banco Bolivariano','C',1,'2023-02-26 09:00:00','admin'),
  ('persona_juridica','0990278901001','VIDRIO Y ALUMINIO INDUSTRIAL S.A.','compras@vidrio.ec','022000026','Calle Eloy Alfaro 45, Machala',30,'33003000026','Banco de Loja','A',1,'2023-03-27 09:00:00','admin'),
  ('persona_juridica','1790289012001','HERRAMIENTAS Y EQUIPOS MENORES S.A.','compras@herramientas.ec','022000027','Av. Amazonas 234, Quito',45,'33003000027','BanEcuador','B',1,'2023-04-28 09:00:00','admin'),
  ('persona_juridica','0990290123001','SEGUROS Y FIANZAS DEL ECUADOR S.A.','compras@seguros.ec','022000028','Km 6 Vía a Salinas, Guayaquil',30,'33003000028','Banco del Austro','A',1,'2023-05-01 09:00:00','admin'),
  ('persona_juridica','1790301234001','TELECOMUNICACIONES REGIONALES S.A.','compras@telecomunicaciones.ec','022000029','Av. Remigio Crespo 678, Cuenca',30,'33003000029','Banco Procredit','A',1,'2023-06-02 09:00:00','admin');

-- ============================================================
-- B.2 ProveedorPersonaNatural  (20 registros)
-- ============================================================
INSERT INTO ProveedorPersonaNatural (id_proveedor, cedula) VALUES
  (1,'1712345678'),
  (2,'1756789012'),
  (3,'0987654321'),
  (4,'1834567890'),
  (5,'0712345678'),
  (6,'1745678901'),
  (7,'1823456789'),
  (8,'0834567890'),
  (9,'1701234567'),
  (10,'1789012345'),
  (11,'0923456789'),
  (12,'1867890123'),
  (13,'0756789012'),
  (14,'1745012345'),
  (15,'1801234567'),
  (16,'0867890123'),
  (17,'1778901234'),
  (18,'0745678901'),
  (19,'1856789012'),
  (20,'0823456789');

-- ============================================================
-- B.3 ProveedorPersonaJuridica  (30 registros)
-- ============================================================
INSERT INTO ProveedorPersonaJuridica (id_proveedor, razon_social, nombre_comercial) VALUES
  (21,'DISTRIMAYORISTA CENTRAL S.A.','DISMAC'),
  (22,'IMPORTACIONES ANDINA CIA. LTDA.','IMPANDINA'),
  (23,'SUMINISTROS TECNOLÓGICOS DEL NORTE S.A.','SUTEKNOR'),
  (24,'ALIMENTOS Y BEBIDAS ECUATORIANAS S.A.','ALBEC'),
  (25,'FERRETERÍA INDUSTRIAL GLOBAL CIA. LTDA.','FIGLOBAL'),
  (26,'PAPELERÍA Y ÚTILES ESCOLARES S.A.','PAULES'),
  (27,'MUEBLES Y DECORACIÓN MODERNA S.A.','MUDEMO'),
  (28,'SERVICIOS LOGÍSTICOS RÁPIDOS CIA. LTDA.','SELOGRA'),
  (29,'MATERIALES DE CONSTRUCCIÓN CENTRO S.A.','MACECEN'),
  (30,'QUÍMICOS Y SOLVENTES INDUSTRIALES S.A.','QUIMISOL'),
  (31,'ELECTRODOMÉSTICOS DEL PACÍFICO S.A.','ELECTROPAC'),
  (32,'TEXTILES NACIONALES CIA. LTDA.','TEXNA'),
  (33,'PRODUCTOS FARMACÉUTICOS ANDES S.A.','PHARANDES'),
  (34,'AGROQUÍMICOS Y FERTILIZANTES S.A.','AGROFERT'),
  (35,'REPUESTOS AUTOMOTRICES DEL SUR S.A.','REPAUTOSUR'),
  (36,'CLIMATIZACIÓN Y REFRIGERACIÓN S.A.','CLIMAREC'),
  (37,'CALZADO Y ARTÍCULOS DE CUERO CIA. LTDA.','CALCUERO'),
  (38,'SISTEMAS INFORMÁTICOS AVANZADOS S.A.','SIAVANZADO'),
  (39,'COMBUSTIBLES Y LUBRICANTES S.A.','COMBILUB'),
  (40,'PUBLICIDAD Y DISEÑO INTEGRAL CIA. LTDA.','PUDINEG'),
  (41,'EQUIPOS MÉDICOS Y HOSPITALARIOS S.A.','EQUIMEDHOP'),
  (42,'CONFECCIONES TEXTILES NACIONALES S.A.','CONTENA'),
  (43,'PLÁSTICOS Y EMPAQUES INDUSTRIALES S.A.','PLASINDU'),
  (44,'ELECTRÓNICA DE CONSUMO S.A.','ELECTRCONS'),
  (45,'PRODUCTOS DE LIMPIEZA HOGAR CIA. LTDA.','PROLIMPIAR'),
  (46,'MAQUINARIA AGRÍCOLA Y PECUARIA S.A.','MAQUIAGRO'),
  (47,'VIDRIO Y ALUMINIO INDUSTRIAL S.A.','VIDALUM'),
  (48,'HERRAMIENTAS Y EQUIPOS MENORES S.A.','HEREQMEN'),
  (49,'SEGUROS Y FIANZAS DEL ECUADOR S.A.','SEGUFIANZA'),
  (50,'TELECOMUNICACIONES REGIONALES S.A.','TELECOREG');

-- ============================================================
-- B.4 OrdenCompra  (55 registros)
-- ============================================================
INSERT INTO OrdenCompra
(numero_oc, id_proveedor, ref_mod_b_id_solicitud, fecha_emision, fecha_entrega_esperada, estado, total_estimado, observaciones, activo, fecha_creacion, usuario_creacion)
VALUES
  ('OC-202401-00001',21,1,'2024-01-15','2024-02-07','recibida_total',12500.0,'Reposición de stock productos electrónicos',1,'2024-01-15 08:30:00','admin'),
  ('OC-202401-00002',22,2,'2024-01-22','2024-02-14','recibida_total',8750.0,'Compra mensual de insumos de oficina',1,'2024-01-22 08:30:00','admin'),
  ('OC-202402-00003',23,3,'2024-02-03','2024-02-23','recibida_total',22000.0,'Pedido especial maquinaria',1,'2024-02-03 08:30:00','admin'),
  ('OC-202402-00004',24,4,'2024-02-14','2024-03-06','recibida_total',5600.0,'Compra rutinaria materiales limpieza',1,'2024-02-14 08:30:00','admin'),
  ('OC-202402-00005',25,5,'2024-02-25','2024-03-17','recibida_total',15000.0,'Reposición línea alimentos',1,'2024-02-25 08:30:00','admin'),
  ('OC-202403-00006',26,6,'2024-03-08','2024-03-28','recibida_total',3400.0,'Insumos de mantenimiento',1,'2024-03-08 08:30:00','admin'),
  ('OC-202403-00007',27,7,'2024-03-19','2024-04-11','recibida_total',9800.0,'Equipos computación área TI',1,'2024-03-19 08:30:00','admin'),
  ('OC-202403-00008',28,8,'2024-03-28','2024-04-20','recibida_total',18500.0,'Materiales construcción obra',1,'2024-03-28 08:30:00','admin'),
  ('OC-202404-00009',29,9,'2024-04-10','2024-05-02','recibida_total',7200.0,'Productos químicos laboratorio',1,'2024-04-10 08:30:00','admin'),
  ('OC-202404-00010',30,10,'2024-04-22','2024-05-14','recibida_total',11000.0,'Repuestos maquinaria producción',1,'2024-04-22 08:30:00','admin'),
  ('OC-202405-00011',31,11,'2024-05-06','2024-05-26','recibida_total',4500.0,'Papelería año lectivo',1,'2024-05-06 08:30:00','admin'),
  ('OC-202405-00012',32,12,'2024-05-17','2024-06-09','recibida_total',26000.0,'Equipos refrigeración planta',1,'2024-05-17 08:30:00','admin'),
  ('OC-202405-00013',33,13,'2024-05-28','2024-06-20','recibida_total',6800.0,'Calzado dotación personal',1,'2024-05-28 08:30:00','admin'),
  ('OC-202406-00014',34,14,'2024-06-10','2024-07-02','recibida_total',14500.0,'Textiles uniformes empresa',1,'2024-06-10 08:30:00','admin'),
  ('OC-202406-00015',35,15,'2024-06-21','2024-07-13','recibida_total',3200.0,'Medicamentos botiquín',1,'2024-06-21 08:30:00','admin'),
  ('OC-202407-00016',36,16,'2024-07-03','2024-07-23','recibida_total',19000.0,'Agroquímicos temporada',1,'2024-07-03 08:30:00','admin'),
  ('OC-202407-00017',37,17,'2024-07-15','2024-08-07','recibida_total',8300.0,'Repuestos automotrices flota',1,'2024-07-15 08:30:00','admin'),
  ('OC-202407-00018',38,18,'2024-07-26','2024-08-18','recibida_total',13700.0,'Equipos climatización oficinas',1,'2024-07-26 08:30:00','admin'),
  ('OC-202408-00019',39,19,'2024-08-07','2024-08-27','recibida_total',5100.0,'Lubricantes mantenimiento',1,'2024-08-07 08:30:00','admin'),
  ('OC-202408-00020',40,20,'2024-08-19','2024-09-11','recibida_total',21000.0,'Material publicitario campaña',1,'2024-08-19 08:30:00','admin'),
  ('OC-202409-00021',41,21,'2024-09-02','2024-09-22','recibida_total',9600.0,'Equipos médicos clínica',1,'2024-09-02 08:30:00','admin'),
  ('OC-202409-00022',42,22,'2024-09-13','2024-10-05','recibida_total',4200.0,'Confecciones especiales',1,'2024-09-13 08:30:00','admin'),
  ('OC-202409-00023',43,23,'2024-09-24','2024-10-16','recibida_total',17500.0,'Empaques producto temporada alta',1,'2024-09-24 08:30:00','admin'),
  ('OC-202410-00024',44,24,'2024-10-07','2024-10-27','recibida_total',6300.0,'Electrónica consumo masivo',1,'2024-10-07 08:30:00','admin'),
  ('OC-202410-00025',45,25,'2024-10-18','2024-11-10','recibida_total',11500.0,'Productos limpieza institucional',1,'2024-10-18 08:30:00','admin'),
  ('OC-202410-00026',46,26,'2024-10-29','2024-11-21','recibida_total',8900.0,'Maquinaria agrícola cosecha',1,'2024-10-29 08:30:00','admin'),
  ('OC-202411-00027',47,27,'2024-11-11','2024-12-03','recibida_total',15200.0,'Vidrio oficinas renovación',1,'2024-11-11 08:30:00','admin'),
  ('OC-202411-00028',48,28,'2024-11-22','2024-12-14','recibida_total',4800.0,'Herramientas taller',1,'2024-11-22 08:30:00','admin'),
  ('OC-202412-00029',49,29,'2024-12-03','2024-12-23','recibida_total',22500.0,'Servicios complementarios',1,'2024-12-03 08:30:00','admin'),
  ('OC-202412-00030',50,30,'2024-12-16','2025-01-08','recibida_total',7600.0,'Equipos telecomunicación',1,'2024-12-16 08:30:00','admin'),
  ('OC-202501-00031',1,NULL,'2025-01-10','2025-02-02','recibida_total',3800.0,'Materiales eléctricos',1,'2025-01-10 08:30:00','admin'),
  ('OC-202501-00032',2,NULL,'2025-01-24','2025-02-16','recibida_total',10200.0,'Insumos cocina cafetería',1,'2025-01-24 08:30:00','admin'),
  ('OC-202502-00033',3,NULL,'2025-02-07','2025-02-27','recibida_total',16800.0,'Productos higiene personal',1,'2025-02-07 08:30:00','admin'),
  ('OC-202502-00034',4,NULL,'2025-02-21','2025-03-13','recibida_total',5400.0,'Artículos escritorio',1,'2025-02-21 08:30:00','admin'),
  ('OC-202503-00035',5,NULL,'2025-03-07','2025-03-27','recibida_total',12100.0,'Equipos seguridad industrial',1,'2025-03-07 08:30:00','admin'),
  ('OC-202503-00036',6,NULL,'2025-03-21','2025-04-13','recibida_total',9300.0,'Materiales embalaje bodega',1,'2025-03-21 08:30:00','admin'),
  ('OC-202504-00037',7,NULL,'2025-04-04','2025-04-24','recibida_total',18900.0,'Productos veterinarios',1,'2025-04-04 08:30:00','admin'),
  ('OC-202504-00038',8,NULL,'2025-04-18','2025-05-10','recibida_total',4100.0,'Fertilizantes orgánicos',1,'2025-04-18 08:30:00','admin'),
  ('OC-202505-00039',9,NULL,'2025-05-02','2025-05-22','recibida_total',14300.0,'Sistemas alarma oficinas',1,'2025-05-02 08:30:00','admin'),
  ('OC-202505-00040',10,NULL,'2025-05-16','2025-06-08','recibida_total',7900.0,'Equipos audiovisuales sala',1,'2025-05-16 08:30:00','admin'),
  ('OC-202506-00041',21,NULL,'2025-06-02','2025-06-22','recibida_total',6200.0,'Suministros plomería',1,'2025-06-02 08:30:00','admin'),
  ('OC-202506-00042',22,NULL,'2025-06-16','2025-07-08','recibida_total',20500.0,'Herramientas jardín',1,'2025-06-16 08:30:00','admin'),
  ('OC-202506-00043',23,NULL,'2025-06-30','2025-07-22','recibida_total',5700.0,'Materiales soldadura',1,'2025-06-30 08:30:00','admin'),
  ('OC-202507-00044',24,NULL,'2025-07-14','2025-08-06','recibida_total',13200.0,'Equipos pintura',1,'2025-07-14 08:30:00','admin'),
  ('OC-202507-00045',25,NULL,'2025-07-28','2025-08-20','recibida_total',8100.0,'Insumos imprenta',1,'2025-07-28 08:30:00','admin'),
  ('OC-202508-00046',11,NULL,'2025-08-11','2025-09-03','recibida_parcial',4400.0,'Productos farmacéuticos emergencia',1,'2025-08-11 08:30:00','admin'),
  ('OC-202508-00047',12,NULL,'2025-08-25','2025-09-17','recibida_parcial',9100.0,'Equipo deportivo',1,'2025-08-25 08:30:00','admin'),
  ('OC-202509-00048',13,NULL,'2025-09-08','2025-09-28','recibida_parcial',16500.0,'Mobiliario oficina nueva',1,'2025-09-08 08:30:00','admin'),
  ('OC-202509-00049',14,NULL,'2025-09-22','2025-10-14','recibida_parcial',5900.0,'Cortinas y persianas',1,'2025-09-22 08:30:00','admin'),
  ('OC-202510-00050',15,NULL,'2025-10-06','2025-10-26','recibida_parcial',11800.0,'Artículos plástico cocina',1,'2025-10-06 08:30:00','admin'),
  ('OC-202510-00051',26,NULL,'2025-10-20','2025-11-12','emitida',7300.0,'Equipos comunicación',1,'2025-10-20 08:30:00','admin'),
  ('OC-202511-00052',27,NULL,'2025-11-03','2025-11-23','emitida',14700.0,'Materiales señalización',1,'2025-11-03 08:30:00','admin'),
  ('OC-202511-00053',28,NULL,'2025-11-17','2025-12-09','emitida',3600.0,'Insumos panadería',1,'2025-11-17 08:30:00','admin'),
  ('OC-202512-00054',29,NULL,'2025-12-01','2025-12-21','emitida',19500.0,'Productos avícola',1,'2025-12-01 08:30:00','admin'),
  ('OC-202512-00055',30,NULL,'2025-12-15','2026-01-07','emitida',8600.0,'Equipos laboratorio calidad',1,'2025-12-15 08:30:00','admin');

-- ============================================================
-- B.5 DetalleOrdenCompra  (110 registros — 2 ítems por OC)
-- ============================================================
INSERT INTO DetalleOrdenCompra
(id_oc, ref_mod_b_id_producto, codigo_producto_al_momento, descripcion_al_momento, unidad_medida_al_momento, cantidad_solicitada, precio_unitario_pactado, subtotal, activo, fecha_creacion, usuario_creacion)
VALUES
  (1,1,'PROD-001','Monitor LED 24 pulgadas','unidad',15,250.0,3750.0,1,'2024-01-15 08:30:00','admin'),
  (1,2,'PROD-002','Teclado inalámbrico USB','unidad',8,35.0,280.0,1,'2024-01-15 08:31:00','admin'),
  (2,2,'PROD-002','Teclado inalámbrico USB','unidad',20,35.0,700.0,1,'2024-01-22 08:30:00','admin'),
  (2,3,'PROD-003','Resma papel bond A4','resma',11,4.5,49.5,1,'2024-01-22 08:31:00','admin'),
  (3,3,'PROD-003','Resma papel bond A4','resma',25,4.5,112.5,1,'2024-02-03 08:30:00','admin'),
  (3,4,'PROD-004','Carpetas archivadoras','unidad',14,2.8,39.2,1,'2024-02-03 08:31:00','admin'),
  (4,4,'PROD-004','Carpetas archivadoras','unidad',30,2.8,84.0,1,'2024-02-14 08:30:00','admin'),
  (4,5,'PROD-005','Caja de marcadores','caja',17,8.5,144.5,1,'2024-02-14 08:31:00','admin'),
  (5,5,'PROD-005','Caja de marcadores','caja',35,8.5,297.5,1,'2024-02-25 08:30:00','admin'),
  (5,6,'PROD-006','Jabón líquido institucional','litro',20,1.2,24.0,1,'2024-02-25 08:31:00','admin'),
  (6,6,'PROD-006','Jabón líquido institucional','litro',40,1.2,48.0,1,'2024-03-08 08:30:00','admin'),
  (6,7,'PROD-007','Desinfectante concentrado','galón',23,6.5,149.5,1,'2024-03-08 08:31:00','admin'),
  (7,7,'PROD-007','Desinfectante concentrado','galón',45,6.5,292.5,1,'2024-03-19 08:30:00','admin'),
  (7,8,'PROD-008','Escobas industriales','unidad',26,4.2,109.2,1,'2024-03-19 08:31:00','admin'),
  (8,8,'PROD-008','Escobas industriales','unidad',50,4.2,210.0,1,'2024-03-28 08:30:00','admin'),
  (8,9,'PROD-009','Cemento Portland 50kg','saco',29,9.8,284.2,1,'2024-03-28 08:31:00','admin'),
  (9,9,'PROD-009','Cemento Portland 50kg','saco',55,9.8,539.0,1,'2024-04-10 08:30:00','admin'),
  (9,10,'PROD-010','Varilla corrugada 12mm','quintal',32,35.0,1120.0,1,'2024-04-10 08:31:00','admin'),
  (10,10,'PROD-010','Varilla corrugada 12mm','quintal',60,35.0,2100.0,1,'2024-04-22 08:30:00','admin'),
  (10,11,'PROD-011','Pintura látex blanco','galón',5,12.5,62.5,1,'2024-04-22 08:31:00','admin'),
  (11,11,'PROD-011','Pintura látex blanco','galón',65,12.5,812.5,1,'2024-05-06 08:30:00','admin'),
  (11,12,'PROD-012','Baldosas cerámicas 40x40','m2',8,8.0,64.0,1,'2024-05-06 08:31:00','admin'),
  (12,12,'PROD-012','Baldosas cerámicas 40x40','m2',70,8.0,560.0,1,'2024-05-17 08:30:00','admin'),
  (12,13,'PROD-013','Aceite hidráulico 20W50','litro',11,3.2,35.2,1,'2024-05-17 08:31:00','admin'),
  (13,13,'PROD-013','Aceite hidráulico 20W50','litro',75,3.2,240.0,1,'2024-05-28 08:30:00','admin'),
  (13,14,'PROD-014','Filtros de aire motores','unidad',14,15.0,210.0,1,'2024-05-28 08:31:00','admin'),
  (14,14,'PROD-014','Filtros de aire motores','unidad',80,15.0,1200.0,1,'2024-06-10 08:30:00','admin'),
  (14,15,'PROD-015','Cable eléctrico 12AWG','metro',17,1.8,30.6,1,'2024-06-10 08:31:00','admin'),
  (15,15,'PROD-015','Cable eléctrico 12AWG','metro',10,1.8,18.0,1,'2024-06-21 08:30:00','admin'),
  (15,16,'PROD-016','Canaletas plásticas 2m','unidad',20,2.5,50.0,1,'2024-06-21 08:31:00','admin'),
  (16,16,'PROD-016','Canaletas plásticas 2m','unidad',15,2.5,37.5,1,'2024-07-03 08:30:00','admin'),
  (16,17,'PROD-017','Disco de corte 4.5 pulgadas','unidad',23,1.5,34.5,1,'2024-07-03 08:31:00','admin'),
  (17,17,'PROD-017','Disco de corte 4.5 pulgadas','unidad',20,1.5,30.0,1,'2024-07-15 08:30:00','admin'),
  (17,18,'PROD-018','Guantes de nitrilo talla M','caja100',26,18.0,468.0,1,'2024-07-15 08:31:00','admin'),
  (18,18,'PROD-018','Guantes de nitrilo talla M','caja100',25,18.0,450.0,1,'2024-07-26 08:30:00','admin'),
  (18,19,'PROD-019','Mascarillas N95','caja50',29,22.0,638.0,1,'2024-07-26 08:31:00','admin'),
  (19,19,'PROD-019','Mascarillas N95','caja50',30,22.0,660.0,1,'2024-08-07 08:30:00','admin'),
  (19,20,'PROD-020','Botiquín de primeros auxilios','unidad',32,45.0,1440.0,1,'2024-08-07 08:31:00','admin'),
  (20,20,'PROD-020','Botiquín de primeros auxilios','unidad',35,45.0,1575.0,1,'2024-08-19 08:30:00','admin'),
  (20,1,'PROD-001','Monitor LED 24 pulgadas','unidad',5,250.0,1250.0,1,'2024-08-19 08:31:00','admin'),
  (21,1,'PROD-001','Monitor LED 24 pulgadas','unidad',40,250.0,10000.0,1,'2024-09-02 08:30:00','admin'),
  (21,2,'PROD-002','Teclado inalámbrico USB','unidad',8,35.0,280.0,1,'2024-09-02 08:31:00','admin'),
  (22,2,'PROD-002','Teclado inalámbrico USB','unidad',45,35.0,1575.0,1,'2024-09-13 08:30:00','admin'),
  (22,3,'PROD-003','Resma papel bond A4','resma',11,4.5,49.5,1,'2024-09-13 08:31:00','admin'),
  (23,3,'PROD-003','Resma papel bond A4','resma',50,4.5,225.0,1,'2024-09-24 08:30:00','admin'),
  (23,4,'PROD-004','Carpetas archivadoras','unidad',14,2.8,39.2,1,'2024-09-24 08:31:00','admin'),
  (24,4,'PROD-004','Carpetas archivadoras','unidad',55,2.8,154.0,1,'2024-10-07 08:30:00','admin'),
  (24,5,'PROD-005','Caja de marcadores','caja',17,8.5,144.5,1,'2024-10-07 08:31:00','admin'),
  (25,5,'PROD-005','Caja de marcadores','caja',60,8.5,510.0,1,'2024-10-18 08:30:00','admin'),
  (25,6,'PROD-006','Jabón líquido institucional','litro',20,1.2,24.0,1,'2024-10-18 08:31:00','admin'),
  (26,6,'PROD-006','Jabón líquido institucional','litro',65,1.2,78.0,1,'2024-10-29 08:30:00','admin'),
  (26,7,'PROD-007','Desinfectante concentrado','galón',23,6.5,149.5,1,'2024-10-29 08:31:00','admin'),
  (27,7,'PROD-007','Desinfectante concentrado','galón',70,6.5,455.0,1,'2024-11-11 08:30:00','admin'),
  (27,8,'PROD-008','Escobas industriales','unidad',26,4.2,109.2,1,'2024-11-11 08:31:00','admin'),
  (28,8,'PROD-008','Escobas industriales','unidad',75,4.2,315.0,1,'2024-11-22 08:30:00','admin'),
  (28,9,'PROD-009','Cemento Portland 50kg','saco',29,9.8,284.2,1,'2024-11-22 08:31:00','admin'),
  (29,9,'PROD-009','Cemento Portland 50kg','saco',80,9.8,784.0,1,'2024-12-03 08:30:00','admin'),
  (29,10,'PROD-010','Varilla corrugada 12mm','quintal',32,35.0,1120.0,1,'2024-12-03 08:31:00','admin'),
  (30,10,'PROD-010','Varilla corrugada 12mm','quintal',10,35.0,350.0,1,'2024-12-16 08:30:00','admin'),
  (30,11,'PROD-011','Pintura látex blanco','galón',5,12.5,62.5,1,'2024-12-16 08:31:00','admin'),
  (31,11,'PROD-011','Pintura látex blanco','galón',15,12.5,187.5,1,'2025-01-10 08:30:00','admin'),
  (31,12,'PROD-012','Baldosas cerámicas 40x40','m2',8,8.0,64.0,1,'2025-01-10 08:31:00','admin'),
  (32,12,'PROD-012','Baldosas cerámicas 40x40','m2',20,8.0,160.0,1,'2025-01-24 08:30:00','admin'),
  (32,13,'PROD-013','Aceite hidráulico 20W50','litro',11,3.2,35.2,1,'2025-01-24 08:31:00','admin'),
  (33,13,'PROD-013','Aceite hidráulico 20W50','litro',25,3.2,80.0,1,'2025-02-07 08:30:00','admin'),
  (33,14,'PROD-014','Filtros de aire motores','unidad',14,15.0,210.0,1,'2025-02-07 08:31:00','admin'),
  (34,14,'PROD-014','Filtros de aire motores','unidad',30,15.0,450.0,1,'2025-02-21 08:30:00','admin'),
  (34,15,'PROD-015','Cable eléctrico 12AWG','metro',17,1.8,30.6,1,'2025-02-21 08:31:00','admin'),
  (35,15,'PROD-015','Cable eléctrico 12AWG','metro',35,1.8,63.0,1,'2025-03-07 08:30:00','admin'),
  (35,16,'PROD-016','Canaletas plásticas 2m','unidad',20,2.5,50.0,1,'2025-03-07 08:31:00','admin'),
  (36,16,'PROD-016','Canaletas plásticas 2m','unidad',40,2.5,100.0,1,'2025-03-21 08:30:00','admin'),
  (36,17,'PROD-017','Disco de corte 4.5 pulgadas','unidad',23,1.5,34.5,1,'2025-03-21 08:31:00','admin'),
  (37,17,'PROD-017','Disco de corte 4.5 pulgadas','unidad',45,1.5,67.5,1,'2025-04-04 08:30:00','admin'),
  (37,18,'PROD-018','Guantes de nitrilo talla M','caja100',26,18.0,468.0,1,'2025-04-04 08:31:00','admin'),
  (38,18,'PROD-018','Guantes de nitrilo talla M','caja100',50,18.0,900.0,1,'2025-04-18 08:30:00','admin'),
  (38,19,'PROD-019','Mascarillas N95','caja50',29,22.0,638.0,1,'2025-04-18 08:31:00','admin'),
  (39,19,'PROD-019','Mascarillas N95','caja50',55,22.0,1210.0,1,'2025-05-02 08:30:00','admin'),
  (39,20,'PROD-020','Botiquín de primeros auxilios','unidad',32,45.0,1440.0,1,'2025-05-02 08:31:00','admin'),
  (40,20,'PROD-020','Botiquín de primeros auxilios','unidad',60,45.0,2700.0,1,'2025-05-16 08:30:00','admin'),
  (40,1,'PROD-001','Monitor LED 24 pulgadas','unidad',5,250.0,1250.0,1,'2025-05-16 08:31:00','admin'),
  (41,1,'PROD-001','Monitor LED 24 pulgadas','unidad',65,250.0,16250.0,1,'2025-06-02 08:30:00','admin'),
  (41,2,'PROD-002','Teclado inalámbrico USB','unidad',8,35.0,280.0,1,'2025-06-02 08:31:00','admin'),
  (42,2,'PROD-002','Teclado inalámbrico USB','unidad',70,35.0,2450.0,1,'2025-06-16 08:30:00','admin'),
  (42,3,'PROD-003','Resma papel bond A4','resma',11,4.5,49.5,1,'2025-06-16 08:31:00','admin'),
  (43,3,'PROD-003','Resma papel bond A4','resma',75,4.5,337.5,1,'2025-06-30 08:30:00','admin'),
  (43,4,'PROD-004','Carpetas archivadoras','unidad',14,2.8,39.2,1,'2025-06-30 08:31:00','admin'),
  (44,4,'PROD-004','Carpetas archivadoras','unidad',80,2.8,224.0,1,'2025-07-14 08:30:00','admin'),
  (44,5,'PROD-005','Caja de marcadores','caja',17,8.5,144.5,1,'2025-07-14 08:31:00','admin'),
  (45,5,'PROD-005','Caja de marcadores','caja',10,8.5,85.0,1,'2025-07-28 08:30:00','admin'),
  (45,6,'PROD-006','Jabón líquido institucional','litro',20,1.2,24.0,1,'2025-07-28 08:31:00','admin'),
  (46,6,'PROD-006','Jabón líquido institucional','litro',15,1.2,18.0,1,'2025-08-11 08:30:00','admin'),
  (46,7,'PROD-007','Desinfectante concentrado','galón',23,6.5,149.5,1,'2025-08-11 08:31:00','admin'),
  (47,7,'PROD-007','Desinfectante concentrado','galón',20,6.5,130.0,1,'2025-08-25 08:30:00','admin'),
  (47,8,'PROD-008','Escobas industriales','unidad',26,4.2,109.2,1,'2025-08-25 08:31:00','admin'),
  (48,8,'PROD-008','Escobas industriales','unidad',25,4.2,105.0,1,'2025-09-08 08:30:00','admin'),
  (48,9,'PROD-009','Cemento Portland 50kg','saco',29,9.8,284.2,1,'2025-09-08 08:31:00','admin'),
  (49,9,'PROD-009','Cemento Portland 50kg','saco',30,9.8,294.0,1,'2025-09-22 08:30:00','admin'),
  (49,10,'PROD-010','Varilla corrugada 12mm','quintal',32,35.0,1120.0,1,'2025-09-22 08:31:00','admin'),
  (50,10,'PROD-010','Varilla corrugada 12mm','quintal',35,35.0,1225.0,1,'2025-10-06 08:30:00','admin'),
  (50,11,'PROD-011','Pintura látex blanco','galón',5,12.5,62.5,1,'2025-10-06 08:31:00','admin'),
  (51,11,'PROD-011','Pintura látex blanco','galón',40,12.5,500.0,1,'2025-10-20 08:30:00','admin'),
  (51,12,'PROD-012','Baldosas cerámicas 40x40','m2',8,8.0,64.0,1,'2025-10-20 08:31:00','admin'),
  (52,12,'PROD-012','Baldosas cerámicas 40x40','m2',45,8.0,360.0,1,'2025-11-03 08:30:00','admin'),
  (52,13,'PROD-013','Aceite hidráulico 20W50','litro',11,3.2,35.2,1,'2025-11-03 08:31:00','admin'),
  (53,13,'PROD-013','Aceite hidráulico 20W50','litro',50,3.2,160.0,1,'2025-11-17 08:30:00','admin'),
  (53,14,'PROD-014','Filtros de aire motores','unidad',14,15.0,210.0,1,'2025-11-17 08:31:00','admin'),
  (54,14,'PROD-014','Filtros de aire motores','unidad',55,15.0,825.0,1,'2025-12-01 08:30:00','admin'),
  (54,15,'PROD-015','Cable eléctrico 12AWG','metro',17,1.8,30.6,1,'2025-12-01 08:31:00','admin'),
  (55,15,'PROD-015','Cable eléctrico 12AWG','metro',60,1.8,108.0,1,'2025-12-15 08:30:00','admin'),
  (55,16,'PROD-016','Canaletas plásticas 2m','unidad',20,2.5,50.0,1,'2025-12-15 08:31:00','admin');

-- ============================================================
-- B.6 Recepcion  (55 registros — una por OC)
-- ============================================================
INSERT INTO Recepcion
(id_oc, fecha_recepcion, tipo_recepcion, notificado_inventario, fecha_notificacion_inventario, usuario_notificacion, observaciones, activo, fecha_creacion, usuario_creacion)
VALUES
  (1,'2024-01-22','completa',1,'2024-01-22 14:00:00','bodeguero','Recepción completa OC #1',1,'2024-01-22 10:00:00','bodeguero'),
  (2,'2024-02-01','completa',1,'2024-02-01 14:00:00','bodeguero','Recepción completa OC #2',1,'2024-02-01 10:00:00','bodeguero'),
  (3,'2024-02-10','completa',1,'2024-02-10 14:00:00','bodeguero','Recepción completa OC #3',1,'2024-02-10 10:00:00','bodeguero'),
  (4,'2024-02-21','completa',1,'2024-02-21 14:00:00','bodeguero','Recepción completa OC #4',1,'2024-02-21 10:00:00','bodeguero'),
  (5,'2024-03-04','completa',1,'2024-03-04 14:00:00','bodeguero','Recepción completa OC #5',1,'2024-03-04 10:00:00','bodeguero'),
  (6,'2024-03-15','completa',1,'2024-03-15 14:00:00','bodeguero','Recepción completa OC #6',1,'2024-03-15 10:00:00','bodeguero'),
  (7,'2024-03-26','completa',1,'2024-03-26 14:00:00','bodeguero','Recepción completa OC #7',1,'2024-03-26 10:00:00','bodeguero'),
  (8,'2024-04-07','completa',1,'2024-04-07 14:00:00','bodeguero','Recepción completa OC #8',1,'2024-04-07 10:00:00','bodeguero'),
  (9,'2024-04-17','completa',1,'2024-04-17 14:00:00','bodeguero','Recepción completa OC #9',1,'2024-04-17 10:00:00','bodeguero'),
  (10,'2024-05-01','completa',1,'2024-05-01 14:00:00','bodeguero','Recepción completa OC #10',1,'2024-05-01 10:00:00','bodeguero'),
  (11,'2024-05-13','completa',1,'2024-05-13 14:00:00','bodeguero','Recepción completa OC #11',1,'2024-05-13 10:00:00','bodeguero'),
  (12,'2024-05-24','completa',1,'2024-05-24 14:00:00','bodeguero','Recepción completa OC #12',1,'2024-05-24 10:00:00','bodeguero'),
  (13,'2024-06-07','completa',1,'2024-06-07 14:00:00','bodeguero','Recepción completa OC #13',1,'2024-06-07 10:00:00','bodeguero'),
  (14,'2024-06-17','completa',1,'2024-06-17 14:00:00','bodeguero','Recepción completa OC #14',1,'2024-06-17 10:00:00','bodeguero'),
  (15,'2024-06-28','completa',1,'2024-06-28 14:00:00','bodeguero','Recepción completa OC #15',1,'2024-06-28 10:00:00','bodeguero'),
  (16,'2024-07-10','completa',1,'2024-07-10 14:00:00','bodeguero','Recepción completa OC #16',1,'2024-07-10 10:00:00','bodeguero'),
  (17,'2024-07-22','completa',1,'2024-07-22 14:00:00','bodeguero','Recepción completa OC #17',1,'2024-07-22 10:00:00','bodeguero'),
  (18,'2024-08-05','completa',1,'2024-08-05 14:00:00','bodeguero','Recepción completa OC #18',1,'2024-08-05 10:00:00','bodeguero'),
  (19,'2024-08-14','completa',1,'2024-08-14 14:00:00','bodeguero','Recepción completa OC #19',1,'2024-08-14 10:00:00','bodeguero'),
  (20,'2024-08-26','completa',1,'2024-08-26 14:00:00','bodeguero','Recepción completa OC #20',1,'2024-08-26 10:00:00','bodeguero'),
  (21,'2024-09-09','completa',1,'2024-09-09 14:00:00','bodeguero','Recepción completa OC #21',1,'2024-09-09 10:00:00','bodeguero'),
  (22,'2024-09-20','completa',1,'2024-09-20 14:00:00','bodeguero','Recepción completa OC #22',1,'2024-09-20 10:00:00','bodeguero'),
  (23,'2024-10-03','completa',1,'2024-10-03 14:00:00','bodeguero','Recepción completa OC #23',1,'2024-10-03 10:00:00','bodeguero'),
  (24,'2024-10-14','completa',1,'2024-10-14 14:00:00','bodeguero','Recepción completa OC #24',1,'2024-10-14 10:00:00','bodeguero'),
  (25,'2024-10-25','completa',1,'2024-10-25 14:00:00','bodeguero','Recepción completa OC #25',1,'2024-10-25 10:00:00','bodeguero'),
  (26,'2024-11-08','completa',1,'2024-11-08 14:00:00','bodeguero','Recepción completa OC #26',1,'2024-11-08 10:00:00','bodeguero'),
  (27,'2024-11-18','completa',1,'2024-11-18 14:00:00','bodeguero','Recepción completa OC #27',1,'2024-11-18 10:00:00','bodeguero'),
  (28,'2024-12-01','completa',1,'2024-12-01 14:00:00','bodeguero','Recepción completa OC #28',1,'2024-12-01 10:00:00','bodeguero'),
  (29,'2024-12-10','completa',1,'2024-12-10 14:00:00','bodeguero','Recepción completa OC #29',1,'2024-12-10 10:00:00','bodeguero'),
  (30,'2024-12-23','completa',1,'2024-12-23 14:00:00','bodeguero','Recepción completa OC #30',1,'2024-12-23 10:00:00','bodeguero'),
  (31,'2025-01-17','completa',1,'2025-01-17 14:00:00','bodeguero','Recepción completa OC #31',1,'2025-01-17 10:00:00','bodeguero'),
  (32,'2025-02-03','completa',1,'2025-02-03 14:00:00','bodeguero','Recepción completa OC #32',1,'2025-02-03 10:00:00','bodeguero'),
  (33,'2025-02-14','completa',1,'2025-02-14 14:00:00','bodeguero','Recepción completa OC #33',1,'2025-02-14 10:00:00','bodeguero'),
  (34,'2025-02-28','completa',1,'2025-02-28 14:00:00','bodeguero','Recepción completa OC #34',1,'2025-02-28 10:00:00','bodeguero'),
  (35,'2025-03-14','completa',1,'2025-03-14 14:00:00','bodeguero','Recepción completa OC #35',1,'2025-03-14 10:00:00','bodeguero'),
  (36,'2025-03-28','completa',1,'2025-03-28 14:00:00','bodeguero','Recepción completa OC #36',1,'2025-03-28 10:00:00','bodeguero'),
  (37,'2025-04-11','completa',1,'2025-04-11 14:00:00','bodeguero','Recepción completa OC #37',1,'2025-04-11 10:00:00','bodeguero'),
  (38,'2025-04-25','completa',1,'2025-04-25 14:00:00','bodeguero','Recepción completa OC #38',1,'2025-04-25 10:00:00','bodeguero'),
  (39,'2025-05-09','completa',1,'2025-05-09 14:00:00','bodeguero','Recepción completa OC #39',1,'2025-05-09 10:00:00','bodeguero'),
  (40,'2025-05-23','completa',1,'2025-05-23 14:00:00','bodeguero','Recepción completa OC #40',1,'2025-05-23 10:00:00','bodeguero'),
  (41,'2025-06-09','completa',1,'2025-06-09 14:00:00','bodeguero','Recepción completa OC #41',1,'2025-06-09 10:00:00','bodeguero'),
  (42,'2025-06-23','completa',1,'2025-06-23 14:00:00','bodeguero','Recepción completa OC #42',1,'2025-06-23 10:00:00','bodeguero'),
  (43,'2025-07-09','completa',1,'2025-07-09 14:00:00','bodeguero','Recepción completa OC #43',1,'2025-07-09 10:00:00','bodeguero'),
  (44,'2025-07-21','completa',1,'2025-07-21 14:00:00','bodeguero','Recepción completa OC #44',1,'2025-07-21 10:00:00','bodeguero'),
  (45,'2025-08-07','completa',1,'2025-08-07 14:00:00','bodeguero','Recepción completa OC #45',1,'2025-08-07 10:00:00','bodeguero'),
  (46,'2025-08-18','parcial',0,NULL,NULL,'Recepción parcial OC #46',1,'2025-08-18 10:00:00','bodeguero'),
  (47,'2025-09-04','parcial',0,NULL,NULL,'Recepción parcial OC #47',1,'2025-09-04 10:00:00','bodeguero'),
  (48,'2025-09-15','parcial',0,NULL,NULL,'Recepción parcial OC #48',1,'2025-09-15 10:00:00','bodeguero'),
  (49,'2025-10-01','parcial',0,NULL,NULL,'Recepción parcial OC #49',1,'2025-10-01 10:00:00','bodeguero'),
  (50,'2025-10-13','parcial',0,NULL,NULL,'Recepción parcial OC #50',1,'2025-10-13 10:00:00','bodeguero'),
  (51,'2025-10-27','parcial',0,NULL,NULL,'Recepción parcial OC #51',1,'2025-10-27 10:00:00','bodeguero'),
  (52,'2025-11-10','parcial',0,NULL,NULL,'Recepción parcial OC #52',1,'2025-11-10 10:00:00','bodeguero'),
  (53,'2025-11-24','parcial',0,NULL,NULL,'Recepción parcial OC #53',1,'2025-11-24 10:00:00','bodeguero'),
  (54,'2025-12-08','parcial',0,NULL,NULL,'Recepción parcial OC #54',1,'2025-12-08 10:00:00','bodeguero'),
  (55,'2025-12-22','parcial',0,NULL,NULL,'Recepción parcial OC #55',1,'2025-12-22 10:00:00','bodeguero');

-- ============================================================
-- B.7 DetalleRecepcion  (110 registros — 2 ítems por recepción)
-- ============================================================
INSERT INTO DetalleRecepcion
(id_recepcion, id_detalle_oc, ref_mod_b_id_producto, cantidad_recibida, activo, fecha_creacion, usuario_creacion)
VALUES
  (1,1,1,15,1,'2024-01-22 10:05:00','bodeguero'),
  (1,2,2,8,1,'2024-01-22 10:06:00','bodeguero'),
  (2,3,2,20,1,'2024-02-01 10:05:00','bodeguero'),
  (2,4,3,11,1,'2024-02-01 10:06:00','bodeguero'),
  (3,5,3,25,1,'2024-02-10 10:05:00','bodeguero'),
  (3,6,4,14,1,'2024-02-10 10:06:00','bodeguero'),
  (4,7,4,30,1,'2024-02-21 10:05:00','bodeguero'),
  (4,8,5,17,1,'2024-02-21 10:06:00','bodeguero'),
  (5,9,5,35,1,'2024-03-04 10:05:00','bodeguero'),
  (5,10,6,20,1,'2024-03-04 10:06:00','bodeguero'),
  (6,11,6,40,1,'2024-03-15 10:05:00','bodeguero'),
  (6,12,7,23,1,'2024-03-15 10:06:00','bodeguero'),
  (7,13,7,45,1,'2024-03-26 10:05:00','bodeguero'),
  (7,14,8,26,1,'2024-03-26 10:06:00','bodeguero'),
  (8,15,8,50,1,'2024-04-07 10:05:00','bodeguero'),
  (8,16,9,29,1,'2024-04-07 10:06:00','bodeguero'),
  (9,17,9,55,1,'2024-04-17 10:05:00','bodeguero'),
  (9,18,10,32,1,'2024-04-17 10:06:00','bodeguero'),
  (10,19,10,60,1,'2024-05-01 10:05:00','bodeguero'),
  (10,20,11,5,1,'2024-05-01 10:06:00','bodeguero'),
  (11,21,11,65,1,'2024-05-13 10:05:00','bodeguero'),
  (11,22,12,8,1,'2024-05-13 10:06:00','bodeguero'),
  (12,23,12,70,1,'2024-05-24 10:05:00','bodeguero'),
  (12,24,13,11,1,'2024-05-24 10:06:00','bodeguero'),
  (13,25,13,75,1,'2024-06-07 10:05:00','bodeguero'),
  (13,26,14,14,1,'2024-06-07 10:06:00','bodeguero'),
  (14,27,14,80,1,'2024-06-17 10:05:00','bodeguero'),
  (14,28,15,17,1,'2024-06-17 10:06:00','bodeguero'),
  (15,29,15,10,1,'2024-06-28 10:05:00','bodeguero'),
  (15,30,16,20,1,'2024-06-28 10:06:00','bodeguero'),
  (16,31,16,15,1,'2024-07-10 10:05:00','bodeguero'),
  (16,32,17,23,1,'2024-07-10 10:06:00','bodeguero'),
  (17,33,17,20,1,'2024-07-22 10:05:00','bodeguero'),
  (17,34,18,26,1,'2024-07-22 10:06:00','bodeguero'),
  (18,35,18,25,1,'2024-08-05 10:05:00','bodeguero'),
  (18,36,19,29,1,'2024-08-05 10:06:00','bodeguero'),
  (19,37,19,30,1,'2024-08-14 10:05:00','bodeguero'),
  (19,38,20,32,1,'2024-08-14 10:06:00','bodeguero'),
  (20,39,20,35,1,'2024-08-26 10:05:00','bodeguero'),
  (20,40,1,5,1,'2024-08-26 10:06:00','bodeguero'),
  (21,41,1,40,1,'2024-09-09 10:05:00','bodeguero'),
  (21,42,2,8,1,'2024-09-09 10:06:00','bodeguero'),
  (22,43,2,45,1,'2024-09-20 10:05:00','bodeguero'),
  (22,44,3,11,1,'2024-09-20 10:06:00','bodeguero'),
  (23,45,3,50,1,'2024-10-03 10:05:00','bodeguero'),
  (23,46,4,14,1,'2024-10-03 10:06:00','bodeguero'),
  (24,47,4,55,1,'2024-10-14 10:05:00','bodeguero'),
  (24,48,5,17,1,'2024-10-14 10:06:00','bodeguero'),
  (25,49,5,60,1,'2024-10-25 10:05:00','bodeguero'),
  (25,50,6,20,1,'2024-10-25 10:06:00','bodeguero'),
  (26,51,6,65,1,'2024-11-08 10:05:00','bodeguero'),
  (26,52,7,23,1,'2024-11-08 10:06:00','bodeguero'),
  (27,53,7,70,1,'2024-11-18 10:05:00','bodeguero'),
  (27,54,8,26,1,'2024-11-18 10:06:00','bodeguero'),
  (28,55,8,75,1,'2024-12-01 10:05:00','bodeguero'),
  (28,56,9,29,1,'2024-12-01 10:06:00','bodeguero'),
  (29,57,9,80,1,'2024-12-10 10:05:00','bodeguero'),
  (29,58,10,32,1,'2024-12-10 10:06:00','bodeguero'),
  (30,59,10,10,1,'2024-12-23 10:05:00','bodeguero'),
  (30,60,11,5,1,'2024-12-23 10:06:00','bodeguero'),
  (31,61,11,15,1,'2025-01-17 10:05:00','bodeguero'),
  (31,62,12,8,1,'2025-01-17 10:06:00','bodeguero'),
  (32,63,12,20,1,'2025-02-03 10:05:00','bodeguero'),
  (32,64,13,11,1,'2025-02-03 10:06:00','bodeguero'),
  (33,65,13,25,1,'2025-02-14 10:05:00','bodeguero'),
  (33,66,14,14,1,'2025-02-14 10:06:00','bodeguero'),
  (34,67,14,30,1,'2025-02-28 10:05:00','bodeguero'),
  (34,68,15,17,1,'2025-02-28 10:06:00','bodeguero'),
  (35,69,15,35,1,'2025-03-14 10:05:00','bodeguero'),
  (35,70,16,20,1,'2025-03-14 10:06:00','bodeguero'),
  (36,71,16,40,1,'2025-03-28 10:05:00','bodeguero'),
  (36,72,17,23,1,'2025-03-28 10:06:00','bodeguero'),
  (37,73,17,45,1,'2025-04-11 10:05:00','bodeguero'),
  (37,74,18,26,1,'2025-04-11 10:06:00','bodeguero'),
  (38,75,18,50,1,'2025-04-25 10:05:00','bodeguero'),
  (38,76,19,29,1,'2025-04-25 10:06:00','bodeguero'),
  (39,77,19,55,1,'2025-05-09 10:05:00','bodeguero'),
  (39,78,20,32,1,'2025-05-09 10:06:00','bodeguero'),
  (40,79,20,60,1,'2025-05-23 10:05:00','bodeguero'),
  (40,80,1,5,1,'2025-05-23 10:06:00','bodeguero'),
  (41,81,1,65,1,'2025-06-09 10:05:00','bodeguero'),
  (41,82,2,8,1,'2025-06-09 10:06:00','bodeguero'),
  (42,83,2,70,1,'2025-06-23 10:05:00','bodeguero'),
  (42,84,3,11,1,'2025-06-23 10:06:00','bodeguero'),
  (43,85,3,75,1,'2025-07-09 10:05:00','bodeguero'),
  (43,86,4,14,1,'2025-07-09 10:06:00','bodeguero'),
  (44,87,4,80,1,'2025-07-21 10:05:00','bodeguero'),
  (44,88,5,17,1,'2025-07-21 10:06:00','bodeguero'),
  (45,89,5,10,1,'2025-08-07 10:05:00','bodeguero'),
  (45,90,6,20,1,'2025-08-07 10:06:00','bodeguero'),
  (46,91,6,12,1,'2025-08-18 10:05:00','bodeguero'),
  (46,92,7,18,1,'2025-08-18 10:06:00','bodeguero'),
  (47,93,7,16,1,'2025-09-04 10:05:00','bodeguero'),
  (47,94,8,20,1,'2025-09-04 10:06:00','bodeguero'),
  (48,95,8,20,1,'2025-09-15 10:05:00','bodeguero'),
  (48,96,9,23,1,'2025-09-15 10:06:00','bodeguero'),
  (49,97,9,24,1,'2025-10-01 10:05:00','bodeguero'),
  (49,98,10,25,1,'2025-10-01 10:06:00','bodeguero'),
  (50,99,10,28,1,'2025-10-13 10:05:00','bodeguero'),
  (50,100,11,4,1,'2025-10-13 10:06:00','bodeguero'),
  (51,101,11,32,1,'2025-10-27 10:05:00','bodeguero'),
  (51,102,12,6,1,'2025-10-27 10:06:00','bodeguero'),
  (52,103,12,36,1,'2025-11-10 10:05:00','bodeguero'),
  (52,104,13,8,1,'2025-11-10 10:06:00','bodeguero'),
  (53,105,13,40,1,'2025-11-24 10:05:00','bodeguero'),
  (53,106,14,11,1,'2025-11-24 10:06:00','bodeguero'),
  (54,107,14,44,1,'2025-12-08 10:05:00','bodeguero'),
  (54,108,15,13,1,'2025-12-08 10:06:00','bodeguero'),
  (55,109,15,48,1,'2025-12-22 10:05:00','bodeguero'),
  (55,110,16,16,1,'2025-12-22 10:06:00','bodeguero');

-- ============================================================
-- B.8 FacturaProveedor  (55 registros)
-- ============================================================
INSERT INTO FacturaProveedor
(numero_factura_proveedor, numero_serie, id_proveedor, id_oc, id_recepcion,
 fecha_emision, base_imponible, monto_iva, total, codigo_sustento, tipo_bien_servicio,
 ref_mod_d_tarifa_id, estado, factura_excepcional, motivo_excepcion, usuario_autorizador,
 fecha_autorizacion, activo, fecha_creacion, usuario_creacion)
VALUES
  ('000000001','001-002',21,1,1,'2024-01-18',10869.57,1630.43,12500.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-01-18 11:00:00','contador'),
  ('000000002','002-003',22,2,2,'2024-01-25',7608.7,1141.3,8750.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-01-25 11:00:00','contador'),
  ('000000003','003-004',23,3,3,'2024-02-06',19130.43,2869.57,22000.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-02-06 11:00:00','contador'),
  ('000000004','004-005',24,4,4,'2024-02-17',4869.57,730.43,5600.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-02-17 11:00:00','contador'),
  ('000000005','005-006',25,5,5,'2024-02-28',13043.48,1956.52,15000.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-02-28 11:00:00','contador'),
  ('000000006','006-007',26,6,6,'2024-03-11',2956.52,443.48,3400.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-03-11 11:00:00','contador'),
  ('000000007','007-008',27,7,7,'2024-03-22',8521.74,1278.26,9800.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-03-22 11:00:00','contador'),
  ('000000008','008-009',28,8,8,'2024-04-03',16086.96,2413.04,18500.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-04-03 11:00:00','contador'),
  ('000000009','009-001',29,9,9,'2024-04-13',6260.87,939.13,7200.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-04-13 11:00:00','contador'),
  ('000000010','001-002',30,10,10,'2024-04-25',9565.22,1434.78,11000.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-04-25 11:00:00','contador'),
  ('000000011','002-003',31,11,11,'2024-05-09',3913.04,586.96,4500.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-05-09 11:00:00','contador'),
  ('000000012','003-004',32,12,12,'2024-05-20',22608.7,3391.3,26000.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-05-20 11:00:00','contador'),
  ('000000013','004-005',33,13,13,'2024-06-03',5913.04,886.96,6800.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-06-03 11:00:00','contador'),
  ('000000014','005-006',34,14,14,'2024-06-13',12608.7,1891.3,14500.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-06-13 11:00:00','contador'),
  ('000000015','006-007',35,15,15,'2024-06-24',2782.61,417.39,3200.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-06-24 11:00:00','contador'),
  ('000000016','007-008',36,16,16,'2024-07-06',16521.74,2478.26,19000.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-07-06 11:00:00','contador'),
  ('000000017','008-009',37,17,17,'2024-07-18',7217.39,1082.61,8300.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-07-18 11:00:00','contador'),
  ('000000018','009-001',38,18,18,'2024-08-01',11913.04,1786.96,13700.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-08-01 11:00:00','contador'),
  ('000000019','001-002',39,19,19,'2024-08-10',4434.78,665.22,5100.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-08-10 11:00:00','contador'),
  ('000000020','002-003',40,20,20,'2024-08-22',18260.87,2739.13,21000.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-08-22 11:00:00','contador'),
  ('000000021','003-004',41,21,21,'2024-09-05',8347.83,1252.17,9600.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-09-05 11:00:00','contador'),
  ('000000022','004-005',42,22,22,'2024-09-16',3652.17,547.83,4200.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-09-16 11:00:00','contador'),
  ('000000023','005-006',43,23,23,'2024-09-27',15217.39,2282.61,17500.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-09-27 11:00:00','contador'),
  ('000000024','006-007',44,24,24,'2024-10-10',5478.26,821.74,6300.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-10-10 11:00:00','contador'),
  ('000000025','007-008',45,25,25,'2024-10-21',10000.0,1500.0,11500.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-10-21 11:00:00','contador'),
  ('000000026','008-009',46,26,26,'2024-11-04',7739.13,1160.87,8900.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-11-04 11:00:00','contador'),
  ('000000027','009-001',47,27,27,'2024-11-14',13217.39,1982.61,15200.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-11-14 11:00:00','contador'),
  ('000000028','001-002',48,28,28,'2024-11-25',4173.91,626.09,4800.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-11-25 11:00:00','contador'),
  ('000000029','002-003',49,29,29,'2024-12-06',19565.22,2934.78,22500.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-12-06 11:00:00','contador'),
  ('000000030','003-004',50,30,30,'2024-12-19',6608.7,991.3,7600.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2024-12-19 11:00:00','contador'),
  ('000000031','004-005',1,31,31,'2025-01-13',3304.35,495.65,3800.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-01-13 11:00:00','contador'),
  ('000000032','005-006',2,32,32,'2025-01-27',8869.57,1330.43,10200.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-01-27 11:00:00','contador'),
  ('000000033','006-007',3,33,33,'2025-02-10',14608.7,2191.3,16800.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-02-10 11:00:00','contador'),
  ('000000034','007-008',4,34,34,'2025-02-24',4695.65,704.35,5400.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-02-24 11:00:00','contador'),
  ('000000035','008-009',5,35,35,'2025-03-10',10521.74,1578.26,12100.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-03-10 11:00:00','contador'),
  ('000000036','009-001',6,36,36,'2025-03-24',8086.96,1213.04,9300.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-03-24 11:00:00','contador'),
  ('000000037','001-002',7,37,37,'2025-04-07',16434.78,2465.22,18900.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-04-07 11:00:00','contador'),
  ('000000038','002-003',8,38,38,'2025-04-21',3565.22,534.78,4100.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-04-21 11:00:00','contador'),
  ('000000039','003-004',9,39,39,'2025-05-05',12434.78,1865.22,14300.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-05-05 11:00:00','contador'),
  ('000000040','004-005',10,40,40,'2025-05-19',6869.57,1030.43,7900.0,'01','bien',1,'retencion_generada',0,NULL,NULL,NULL,1,'2025-05-19 11:00:00','contador'),
  ('000000041','005-006',21,41,41,'2025-06-05',5391.3,808.7,6200.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-06-05 11:00:00','contador'),
  ('000000042','006-007',22,42,42,'2025-06-19',17826.09,2673.91,20500.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-06-19 11:00:00','contador'),
  ('000000043','007-008',23,43,43,'2025-07-05',4956.52,743.48,5700.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-07-05 11:00:00','contador'),
  ('000000044','008-009',24,44,44,'2025-07-17',11478.26,1721.74,13200.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-07-17 11:00:00','contador'),
  ('000000045','009-001',25,45,45,'2025-08-03',7043.48,1056.52,8100.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-08-03 11:00:00','contador'),
  ('000000046','001-002',11,46,46,'2025-08-14',3826.09,573.91,4400.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-08-14 11:00:00','contador'),
  ('000000047','002-003',12,47,47,'2025-08-28',7913.04,1186.96,9100.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-08-28 11:00:00','contador'),
  ('000000048','003-004',13,48,48,'2025-09-11',14347.83,2152.17,16500.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-09-11 11:00:00','contador'),
  ('000000049','004-005',14,49,49,'2025-09-25',5130.43,769.57,5900.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-09-25 11:00:00','contador'),
  ('000000050','005-006',15,50,50,'2025-10-09',10260.87,1539.13,11800.0,'01','bien',1,'pendiente_retencion',0,NULL,NULL,NULL,1,'2025-10-09 11:00:00','contador'),
  ('000000051','006-007',26,51,51,'2025-10-23',6347.83,952.17,7300.0,'01','bien',1,'anulada',0,NULL,NULL,NULL,1,'2025-10-23 11:00:00','contador'),
  ('000000052','007-008',27,52,52,'2025-11-06',12782.61,1917.39,14700.0,'01','bien',1,'anulada',0,NULL,NULL,NULL,1,'2025-11-06 11:00:00','contador'),
  ('000000053','008-009',28,53,53,'2025-11-20',3130.43,469.57,3600.0,'01','bien',1,'anulada',0,NULL,NULL,NULL,1,'2025-11-20 11:00:00','contador'),
  ('000000054','009-001',29,54,54,'2025-12-04',16956.52,2543.48,19500.0,'01','bien',1,'anulada',0,NULL,NULL,NULL,1,'2025-12-04 11:00:00','contador'),
  ('000000055','001-002',30,55,55,'2025-12-18',7478.26,1121.74,8600.0,'01','bien',1,'anulada',0,NULL,NULL,NULL,1,'2025-12-18 11:00:00','contador');

-- ============================================================
-- B.9 CuentaPorPagar  (55 registros — 1 por factura, UNIQUE)
-- ============================================================
INSERT INTO CuentaPorPagar
(id_proveedor, id_factura_prov, monto_original, saldo_pendiente, fecha_vencimiento, fecha_programada, estado, activo, fecha_creacion, usuario_creacion)
VALUES
  (21,1,12500.0,0.0,'2024-02-20','2024-02-20','pagada',1,'2024-01-18 11:30:00','contador'),
  (22,2,8750.0,0.0,'2024-03-14','2024-03-14','pagada',1,'2024-01-25 11:30:00','contador'),
  (23,3,22000.0,0.0,'2024-04-10','2024-04-10','pagada',1,'2024-02-06 11:30:00','contador'),
  (24,4,5600.0,0.0,'2024-03-19','2024-03-19','pagada',1,'2024-02-17 11:30:00','contador'),
  (25,5,15000.0,0.0,'2024-04-02','2024-04-02','pagada',1,'2024-02-28 11:30:00','contador'),
  (26,6,3400.0,0.0,'2024-03-26','2024-03-26','pagada',1,'2024-03-11 11:30:00','contador'),
  (27,7,9800.0,0.0,'2024-05-11','2024-05-11','pagada',1,'2024-03-22 11:30:00','contador'),
  (28,8,18500.0,0.0,'2024-05-05','2024-05-05','pagada',1,'2024-04-03 11:30:00','contador'),
  (29,9,7200.0,0.0,'2024-06-17','2024-06-17','pagada',1,'2024-04-13 11:30:00','contador'),
  (30,10,11000.0,0.0,'2024-05-27','2024-05-27','pagada',1,'2024-04-25 11:30:00','contador'),
  (31,11,4500.0,0.0,'2024-06-26','2024-06-26','pagada',1,'2024-05-09 11:30:00','contador'),
  (32,12,26000.0,0.0,'2024-06-22','2024-06-22','pagada',1,'2024-05-20 11:30:00','contador'),
  (33,13,6800.0,0.0,'2024-07-05','2024-07-05','pagada',1,'2024-06-03 11:30:00','contador'),
  (34,14,14500.0,0.0,'2024-08-17','2024-08-17','pagada',1,'2024-06-13 11:30:00','contador'),
  (35,15,3200.0,0.0,'2024-07-11','2024-07-11','pagada',1,'2024-06-24 11:30:00','contador'),
  (36,16,19000.0,0.0,'2024-08-23','2024-08-23','pagada',1,'2024-07-06 11:30:00','contador'),
  (37,17,8300.0,0.0,'2024-08-20','2024-08-20','pagada',1,'2024-07-18 11:30:00','contador'),
  (38,18,13700.0,0.0,'2024-09-03','2024-09-03','pagada',1,'2024-08-01 11:30:00','contador'),
  (39,19,5100.0,0.0,'2024-09-27','2024-09-27','pagada',1,'2024-08-10 11:30:00','contador'),
  (40,20,21000.0,0.0,'2024-10-26','2024-10-26','pagada',1,'2024-08-22 11:30:00','contador'),
  (41,21,9600.0,0.0,'2024-10-07','2024-10-07','pagada',1,'2024-09-05 11:30:00','contador'),
  (42,22,4200.0,0.0,'2024-10-18','2024-10-18','pagada',1,'2024-09-16 11:30:00','contador'),
  (43,23,17500.0,0.0,'2024-11-16','2024-11-16','pagada',1,'2024-09-27 11:30:00','contador'),
  (44,24,6300.0,0.0,'2024-11-12','2024-11-12','pagada',1,'2024-10-10 11:30:00','contador'),
  (45,25,11500.0,0.0,'2024-11-08','2024-11-08','pagada',1,'2024-10-21 11:30:00','contador'),
  (46,26,8900.0,0.0,'2025-01-08','2025-01-08','pagada',1,'2024-11-04 11:30:00','contador'),
  (47,27,15200.0,0.0,'2024-12-16','2024-12-16','pagada',1,'2024-11-14 11:30:00','contador'),
  (48,28,4800.0,0.0,'2025-01-14','2025-01-14','pagada',1,'2024-11-25 11:30:00','contador'),
  (49,29,22500.0,0.0,'2025-01-08','2025-01-08','pagada',1,'2024-12-06 11:30:00','contador'),
  (50,30,7600.0,0.0,'2025-01-21','2025-01-21','pagada',1,'2024-12-19 11:30:00','contador'),
  (1,31,3800.0,1520.0,'2025-01-28','2025-01-28','pagada_parcial',1,'2025-01-13 11:30:00','contador'),
  (2,32,10200.0,4080.0,'2025-03-01','2025-03-01','pagada_parcial',1,'2025-01-27 11:30:00','contador'),
  (3,33,16800.0,6720.0,'2025-03-27','2025-03-27','pagada_parcial',1,'2025-02-10 11:30:00','contador'),
  (4,34,5400.0,2160.0,'2025-03-26','2025-03-26','pagada_parcial',1,'2025-02-24 11:30:00','contador'),
  (5,35,12100.0,4840.0,'2025-05-14','2025-05-14','pagada_parcial',1,'2025-03-10 11:30:00','contador'),
  (6,36,9300.0,3720.0,'2025-04-26','2025-04-26','pagada_parcial',1,'2025-03-24 11:30:00','contador'),
  (7,37,18900.0,7560.0,'2025-04-22','2025-04-22','pagada_parcial',1,'2025-04-07 11:30:00','contador'),
  (8,38,4100.0,1640.0,'2025-05-23','2025-05-23','pagada_parcial',1,'2025-04-21 11:30:00','contador'),
  (9,39,14300.0,5720.0,'2025-06-22','2025-06-22','pagada_parcial',1,'2025-05-05 11:30:00','contador'),
  (10,40,7900.0,3160.0,'2025-06-21','2025-06-21','pagada_parcial',1,'2025-05-19 11:30:00','contador'),
  (21,41,6200.0,6200.0,'2025-07-07','2025-07-07','pendiente',1,'2025-06-05 11:30:00','contador'),
  (22,42,20500.0,20500.0,'2025-08-08','2025-08-08','pendiente',1,'2025-06-19 11:30:00','contador'),
  (23,43,5700.0,5700.0,'2025-09-09','2025-09-09','pendiente',1,'2025-07-05 11:30:00','contador'),
  (24,44,13200.0,13200.0,'2025-08-19','2025-08-19','pendiente',1,'2025-07-17 11:30:00','contador'),
  (25,45,8100.0,8100.0,'2025-09-05','2025-09-05','pendiente',1,'2025-08-03 11:30:00','contador'),
  (11,46,4400.0,4400.0,'2025-10-18','2025-10-18','pendiente',1,'2025-08-14 11:30:00','contador'),
  (12,47,9100.0,9100.0,'2025-10-02','2025-10-02','pendiente',1,'2025-08-28 11:30:00','contador'),
  (13,48,16500.0,16500.0,'2025-09-26','2025-09-26','pendiente',1,'2025-09-11 11:30:00','contador'),
  (14,49,5900.0,5900.0,'2025-11-14','2025-11-14','pendiente',1,'2025-09-25 11:30:00','contador'),
  (15,50,11800.0,11800.0,'2025-11-11','2025-11-11','pendiente',1,'2025-10-09 11:30:00','contador'),
  (26,51,7300.0,7300.0,'2025-11-10',NULL,'vencida',1,'2025-10-23 11:30:00','contador'),
  (27,52,14700.0,14700.0,'2025-12-23',NULL,'vencida',1,'2025-11-06 11:30:00','contador'),
  (28,53,3600.0,3600.0,'2025-12-22',NULL,'vencida',1,'2025-11-20 11:30:00','contador'),
  (29,54,19500.0,19500.0,'2026-02-08',NULL,'vencida',1,'2025-12-04 11:30:00','contador'),
  (30,55,8600.0,8600.0,'2026-01-20',NULL,'vencida',1,'2025-12-18 11:30:00','contador');

-- ============================================================
-- B.10 PagoProveedor  (60 registros)
-- Nota: el trigger trg_pago_after_insert actualizará
-- saldo_pendiente y estado en CuentaPorPagar automáticamente.
-- Para los datos de prueba insertamos directamente.
-- ============================================================
SET @trigger_disabled = 1; -- Variable de sesión para pruebas
INSERT INTO PagoProveedor
(id_cxp, id_proveedor, fecha_pago, monto, forma_pago, referencia, activo, fecha_creacion, usuario_creacion)
VALUES
  (1,21,'2024-02-07',12500.0,'transferencia','TRF-2024-00001',1,'2024-02-07 14:00:00','tesorero'),
  (2,22,'2024-02-14',8750.0,'cheque','TRF-2024-00002',1,'2024-02-14 14:00:00','tesorero'),
  (3,23,'2024-02-23',22000.0,'efectivo','TRF-2024-00003',1,'2024-02-23 14:00:00','tesorero'),
  (4,24,'2024-03-06',5600.0,'transferencia','TRF-2024-00004',1,'2024-03-06 14:00:00','tesorero'),
  (5,25,'2024-03-17',15000.0,'transferencia','TRF-2024-00005',1,'2024-03-17 14:00:00','tesorero'),
  (6,26,'2024-03-28',3400.0,'cheque','TRF-2024-00006',1,'2024-03-28 14:00:00','tesorero'),
  (7,27,'2024-04-11',9800.0,'transferencia','TRF-2024-00007',1,'2024-04-11 14:00:00','tesorero'),
  (8,28,'2024-04-20',18500.0,'efectivo','TRF-2024-00008',1,'2024-04-20 14:00:00','tesorero'),
  (9,29,'2024-05-02',7200.0,'transferencia','TRF-2024-00009',1,'2024-05-02 14:00:00','tesorero'),
  (10,30,'2024-05-14',11000.0,'cheque','TRF-2024-00010',1,'2024-05-14 14:00:00','tesorero'),
  (11,31,'2024-05-26',4500.0,'transferencia','TRF-2024-00011',1,'2024-05-26 14:00:00','tesorero'),
  (12,32,'2024-06-09',26000.0,'cheque','TRF-2024-00012',1,'2024-06-09 14:00:00','tesorero'),
  (13,33,'2024-06-20',6800.0,'efectivo','TRF-2025-00013',1,'2024-06-20 14:00:00','tesorero'),
  (14,34,'2024-07-02',14500.0,'transferencia','TRF-2025-00014',1,'2024-07-02 14:00:00','tesorero'),
  (15,35,'2024-07-13',3200.0,'transferencia','TRF-2025-00015',1,'2024-07-13 14:00:00','tesorero'),
  (16,36,'2024-07-23',19000.0,'cheque','TRF-2025-00016',1,'2024-07-23 14:00:00','tesorero'),
  (17,37,'2024-08-07',8300.0,'transferencia','TRF-2025-00017',1,'2024-08-07 14:00:00','tesorero'),
  (18,38,'2024-08-18',13700.0,'efectivo','TRF-2025-00018',1,'2024-08-18 14:00:00','tesorero'),
  (19,39,'2024-08-27',5100.0,'transferencia','TRF-2025-00019',1,'2024-08-27 14:00:00','tesorero'),
  (20,40,'2024-09-11',21000.0,'cheque','TRF-2025-00020',1,'2024-09-11 14:00:00','tesorero'),
  (21,41,'2024-09-22',9600.0,'transferencia','TRF-2025-00021',1,'2024-09-22 14:00:00','tesorero'),
  (22,42,'2024-10-05',4200.0,'cheque','TRF-2025-00022',1,'2024-10-05 14:00:00','tesorero'),
  (23,43,'2024-10-16',17500.0,'efectivo','TRF-2025-00023',1,'2024-10-16 14:00:00','tesorero'),
  (24,44,'2024-10-27',6300.0,'transferencia','TRF-2025-00024',1,'2024-10-27 14:00:00','tesorero'),
  (25,45,'2024-11-10',11500.0,'transferencia','TRF-2026-00025',1,'2024-11-10 14:00:00','tesorero'),
  (26,46,'2024-11-21',8900.0,'cheque','TRF-2026-00026',1,'2024-11-21 14:00:00','tesorero'),
  (27,47,'2024-12-03',15200.0,'transferencia','TRF-2026-00027',1,'2024-12-03 14:00:00','tesorero'),
  (28,48,'2024-12-14',4800.0,'efectivo','TRF-2026-00028',1,'2024-12-14 14:00:00','tesorero'),
  (29,49,'2024-12-23',22500.0,'transferencia','TRF-2026-00029',1,'2024-12-23 14:00:00','tesorero'),
  (30,50,'2025-01-08',7600.0,'cheque','TRF-2026-00030',1,'2025-01-08 14:00:00','tesorero'),
  (31,1,'2025-01-25',1140.0,'transferencia','TRF-PARC1-0031',1,'2025-01-25 14:00:00','tesorero'),
  (31,1,'2025-02-12',1140.0,'cheque','TRF-PARC2-0031',1,'2025-02-12 14:00:00','tesorero'),
  (32,2,'2025-02-11',3060.0,'transferencia','TRF-PARC1-0032',1,'2025-02-11 14:00:00','tesorero'),
  (32,2,'2025-02-26',3060.0,'cheque','TRF-PARC2-0032',1,'2025-02-26 14:00:00','tesorero'),
  (33,3,'2025-02-22',5040.0,'transferencia','TRF-PARC1-0033',1,'2025-02-22 14:00:00','tesorero'),
  (33,3,'2025-03-09',5040.0,'cheque','TRF-PARC2-0033',1,'2025-03-09 14:00:00','tesorero'),
  (34,4,'2025-03-08',1620.0,'transferencia','TRF-PARC1-0034',1,'2025-03-08 14:00:00','tesorero'),
  (34,4,'2025-03-23',1620.0,'cheque','TRF-PARC2-0034',1,'2025-03-23 14:00:00','tesorero'),
  (35,5,'2025-03-22',3630.0,'transferencia','TRF-PARC1-0035',1,'2025-03-22 14:00:00','tesorero'),
  (35,5,'2025-04-09',3630.0,'cheque','TRF-PARC2-0035',1,'2025-04-09 14:00:00','tesorero'),
  (36,6,'2025-04-08',2790.0,'transferencia','TRF-PARC1-0036',1,'2025-04-08 14:00:00','tesorero'),
  (36,6,'2025-04-23',2790.0,'cheque','TRF-PARC2-0036',1,'2025-04-23 14:00:00','tesorero'),
  (37,7,'2025-04-19',5670.0,'transferencia','TRF-PARC1-0037',1,'2025-04-19 14:00:00','tesorero'),
  (37,7,'2025-05-06',5670.0,'cheque','TRF-PARC2-0037',1,'2025-05-06 14:00:00','tesorero'),
  (38,8,'2025-05-05',1230.0,'transferencia','TRF-PARC1-0038',1,'2025-05-05 14:00:00','tesorero'),
  (38,8,'2025-05-20',1230.0,'cheque','TRF-PARC2-0038',1,'2025-05-20 14:00:00','tesorero'),
  (39,9,'2025-05-17',4290.0,'transferencia','TRF-PARC1-0039',1,'2025-05-17 14:00:00','tesorero'),
  (39,9,'2025-06-04',4290.0,'cheque','TRF-PARC2-0039',1,'2025-06-04 14:00:00','tesorero'),
  (40,10,'2025-06-03',2370.0,'transferencia','TRF-PARC1-0040',1,'2025-06-03 14:00:00','tesorero'),
  (40,10,'2025-06-18',2370.0,'cheque','TRF-PARC2-0040',1,'2025-06-18 14:00:00','tesorero');

-- Total de pagos insertados: 50 registros

-- ============================================================
-- C. VERIFICACIÓN DE CONSISTENCIA
-- Actualizar saldo de CXPs pagadas parciales
-- (el trigger trg_pago_after_insert maneja inserciones futuras)
-- ============================================================
UPDATE CuentaPorPagar SET saldo_pendiente = 0.00, estado = 'pagada'
WHERE id_cxp BETWEEN 1 AND 30;

-- Actualizar saldos de pagadas_parciales (40% restante)
UPDATE CuentaPorPagar cp
JOIN (
    SELECT id_cxp, SUM(monto) AS total_pagado
    FROM PagoProveedor WHERE activo = 1 GROUP BY id_cxp
) pp ON cp.id_cxp = pp.id_cxp
SET cp.saldo_pendiente = GREATEST(0, cp.monto_original - pp.total_pagado),
    cp.estado = CASE
        WHEN (cp.monto_original - pp.total_pagado) <= 0 THEN 'pagada'
        ELSE 'pagada_parcial'
    END
WHERE cp.id_cxp BETWEEN 31 AND 40;

-- ============================================================
-- D. VERIFICACIÓN RÁPIDA
-- ============================================================
SELECT 'Proveedor'          AS tabla, COUNT(*) AS total FROM Proveedor          UNION ALL
SELECT 'ProvPersonaNatural', COUNT(*) FROM ProveedorPersonaNatural              UNION ALL
SELECT 'ProvPersonaJuridica',COUNT(*) FROM ProveedorPersonaJuridica             UNION ALL
SELECT 'OrdenCompra',        COUNT(*) FROM OrdenCompra                          UNION ALL
SELECT 'DetalleOrdenCompra', COUNT(*) FROM DetalleOrdenCompra                  UNION ALL
SELECT 'Recepcion',          COUNT(*) FROM Recepcion                            UNION ALL
SELECT 'DetalleRecepcion',   COUNT(*) FROM DetalleRecepcion                     UNION ALL
SELECT 'FacturaProveedor',   COUNT(*) FROM FacturaProveedor                     UNION ALL
SELECT 'CuentaPorPagar',     COUNT(*) FROM CuentaPorPagar                       UNION ALL
SELECT 'PagoProveedor',      COUNT(*) FROM PagoProveedor;

