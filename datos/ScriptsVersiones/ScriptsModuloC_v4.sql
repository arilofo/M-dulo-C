-- ============================================================
--  ENTREGABLE A — MÓDULO C: CUENTAS POR PAGAR
--  Proyecto Final Integrador — Sistema de Gestión Empresarial
--  Bases de Datos II (ICC401) · Universidad del Azuay
--  Período: Febrero–Junio 2026
-- ============================================================
--
--  HISTORIAL DE CAMBIOS
--  ────────────────────
--  v2 (alineación con InformeSoftware v6):
--  • Eliminada la Sección de TRIGGERS completa (ADR actualizado):
--    lógica trasladada a SPs mediante patrón Observer.
--  • Estado 'recibida_completa' → 'recibida_total' (diagrama de clases).
--  • sp_registrar_recepcion incorpora ActualizadorEstadoOrdenCompra.
--  • sp_ingresar_factura_proveedor llama sp_generar_cuenta_por_pagar.
--  • sp_registrar_pago incorpora actualización de saldo/estado CxP.
--  • sp_eliminar_orden_logico reemplaza trigger de cascade.
--
--  v3 (correcciones técnicas):
--  • sp_crear_orden_compra: estado inicial 'enviada' (CU-02).
--  • sp_registrar_pago: SELECT dentro de START TRANSACTION con FOR UPDATE.
--  • fn_calcular_fecha_vencimiento: NOT DETERMINISTIC (lee tabla).
--
--  v4 (revisión minuciosa contra InformeSoftware v6):
--  • [FIX-1] num_autorizacion_retencion: VARCHAR(49) según B.4 y diagrama
--    de clases (antes VARCHAR(50)). Corregido en tabla y SP.
--  • [FIX-2] fn_dias_vencimiento: NOT DETERMINISTIC (usa CURDATE();
--    antes marcada DETERMINISTIC, lo cual es incorrecto).
--  • [FIX-3] Agregados fecha_eliminacion y eliminado_por a TODAS las
--    entidades del diagrama de clases (sección d) que los requerían:
--    ordenes_compra, detalle_orden_compra, recepciones, detalle_recepcion,
--    facturas_proveedor, cuentas_por_pagar, pagos_proveedor.
--    Convención de borrado lógico completa (B.4).
--  • [FIX-4] Agregados sp_consultar_precio_costo_producto y
--    sp_consultar_ultimo_costo_adquisicion implementando la interfaz
--    ServicioConsultaCostosA (CU-14 / RF16 / IF-01), ausentes en v3.
--  • [FIX-5] sp_eliminar_orden_logico: cascada lógica extendida a
--    recepciones y detalle_recepcion (B.4: "eliminar padre implica
--    eliminar hijos en el mismo BEGIN/COMMIT").
--    Ahora también escribe fecha_eliminacion y eliminado_por.
-- ============================================================

-- ============================================================
-- 0. SETUP DEL SCHEMA
-- ============================================================
DROP SCHEMA IF EXISTS modulo_c;
CREATE SCHEMA modulo_c
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_unicode_ci;

USE modulo_c;

-- ============================================================
-- 1. TABLAS PROPIAS DEL MÓDULO C
-- ============================================================

-- ------------------------------------------------------------
-- 1.1 proveedores  (tabla raíz del módulo)
-- Diagrama de clases — clase abstracta Proveedor (sección d)
-- ------------------------------------------------------------
CREATE TABLE proveedores (
    id_proveedor        INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    tipo_proveedor      ENUM('persona_natural','persona_juridica') NOT NULL,
    identificacion      VARCHAR(20)     NOT NULL,
    razon_social        VARCHAR(200)    NOT NULL,
    email               VARCHAR(150)    NULL,
    telefono            VARCHAR(20)     NULL,
    direccion           VARCHAR(300)    NULL,
    dias_credito        INT             NOT NULL DEFAULT 30,
    cuenta_bancaria     VARCHAR(50)     NULL,
    banco               VARCHAR(100)    NULL,
    calificacion        ENUM('A','B','C') NULL,
    activo              TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion      DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion    VARCHAR(100)    NULL,
    fecha_eliminacion   DATETIME        NULL,
    eliminado_por       VARCHAR(100)    NULL,

    CONSTRAINT pk_proveedores           PRIMARY KEY (id_proveedor),
    CONSTRAINT uq_proveedores_ruc       UNIQUE      (identificacion),
    CONSTRAINT chk_prov_dias_credito    CHECK (dias_credito >= 0),
    CONSTRAINT chk_prov_tipo            CHECK (tipo_proveedor IN ('persona_natural','persona_juridica'))
);

CREATE INDEX idx_prov_activo       ON proveedores (activo);
CREATE INDEX idx_prov_tipo         ON proveedores (tipo_proveedor);
CREATE INDEX idx_prov_calificacion ON proveedores (calificacion);

-- ------------------------------------------------------------
-- 1.2 prov_persona_natural  (subtipo de proveedores)
-- Diagrama de clases — ProveedorPersonaNatural (sección d)
-- ------------------------------------------------------------
CREATE TABLE prov_persona_natural (
    id_proveedor    INT UNSIGNED NOT NULL,
    cedula          VARCHAR(10)  NOT NULL,

    CONSTRAINT pk_ppn            PRIMARY KEY (id_proveedor),
    CONSTRAINT uq_ppn_cedula     UNIQUE      (cedula),
    CONSTRAINT fk_ppn_proveedor  FOREIGN KEY (id_proveedor)
        REFERENCES proveedores (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ------------------------------------------------------------
-- 1.3 prov_persona_juridica  (subtipo de proveedores)
-- Diagrama de clases — ProveedorPersonaJuridica (sección d)
-- ------------------------------------------------------------
CREATE TABLE prov_persona_juridica (
    id_proveedor        INT UNSIGNED    NOT NULL,
    razon_social        VARCHAR(200)    NOT NULL,
    nombre_comercial    VARCHAR(200)    NULL,

    CONSTRAINT pk_ppj            PRIMARY KEY (id_proveedor),
    CONSTRAINT fk_ppj_proveedor  FOREIGN KEY (id_proveedor)
        REFERENCES proveedores (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ------------------------------------------------------------
-- 1.4 ordenes_compra
-- Diagrama de clases — OrdenCompra (sección d)
-- Estado 'recibida_total' alineado con diagrama de clases v6.
-- [FIX-3] Agregados fecha_eliminacion y eliminado_por (diagrama d / B.4)
-- ------------------------------------------------------------
CREATE TABLE ordenes_compra (
    id_oc                   INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    numero_oc               VARCHAR(20)     NOT NULL,
    id_proveedor            INT UNSIGNED    NOT NULL,
    ref_mod_b_id_solicitud  INT UNSIGNED    NULL,
    fecha_emision           DATE            NOT NULL,
    fecha_entrega_esperada  DATE            NULL,
    estado                  ENUM('borrador','enviada','recibida_parcial','recibida_total','anulada')
                                            NOT NULL DEFAULT 'borrador',
    total_estimado          DECIMAL(12,2)   NULL,
    observaciones           TEXT            NULL,
    activo                  TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion          DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion        VARCHAR(100)    NULL,
    fecha_modificacion      DATETIME        NULL,
    usuario_modificacion    VARCHAR(100)    NULL,
    fecha_eliminacion       DATETIME        NULL,
    eliminado_por           VARCHAR(100)    NULL,

    CONSTRAINT pk_ordenes_compra        PRIMARY KEY (id_oc),
    CONSTRAINT uq_oc_numero             UNIQUE      (numero_oc),
    CONSTRAINT fk_oc_proveedor          FOREIGN KEY (id_proveedor)
        REFERENCES proveedores (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_oc_total             CHECK (total_estimado IS NULL OR total_estimado >= 0),
    CONSTRAINT chk_oc_fechas            CHECK (fecha_entrega_esperada IS NULL OR fecha_entrega_esperada >= fecha_emision)
);

CREATE INDEX idx_oc_fecha_emision   ON ordenes_compra (fecha_emision);
CREATE INDEX idx_oc_proveedor       ON ordenes_compra (id_proveedor);
CREATE INDEX idx_oc_estado          ON ordenes_compra (estado);
CREATE INDEX idx_oc_solicitud_b     ON ordenes_compra (ref_mod_b_id_solicitud);

-- ------------------------------------------------------------
-- 1.5 detalle_orden_compra
-- Diagrama de clases — DetalleOrdenCompra (sección d)
-- [FIX-3] Agregados fecha_eliminacion y eliminado_por (diagrama d / B.4)
-- ------------------------------------------------------------
CREATE TABLE detalle_orden_compra (
    id_detalle_oc               INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_oc                       INT UNSIGNED    NOT NULL,
    ref_mod_b_id_producto       INT UNSIGNED    NOT NULL,
    descripcion_al_momento      VARCHAR(200)    NOT NULL,
    cantidad_solicitada         INT             NOT NULL,
    precio_unitario_pactado     DECIMAL(12,2)   NOT NULL,
    subtotal                    DECIMAL(12,2)   NOT NULL,
    activo                      TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion              DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion            VARCHAR(100)    NULL,
    fecha_eliminacion           DATETIME        NULL,
    eliminado_por               VARCHAR(100)    NULL,

    CONSTRAINT pk_detalle_oc            PRIMARY KEY (id_detalle_oc),
    CONSTRAINT fk_detoc_oc              FOREIGN KEY (id_oc)
        REFERENCES ordenes_compra (id_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_detoc_cantidad       CHECK (cantidad_solicitada > 0),
    CONSTRAINT chk_detoc_precio         CHECK (precio_unitario_pactado >= 0),
    CONSTRAINT chk_detoc_subtotal       CHECK (subtotal >= 0)
);

CREATE INDEX idx_detoc_oc           ON detalle_orden_compra (id_oc);
CREATE INDEX idx_detoc_producto_b   ON detalle_orden_compra (ref_mod_b_id_producto);

-- ------------------------------------------------------------
-- 1.6 recepciones
-- Diagrama de clases — Recepcion <<Subject>> (sección d)
-- [FIX-3] Agregados fecha_eliminacion y eliminado_por (diagrama d / B.4)
-- ------------------------------------------------------------
CREATE TABLE recepciones (
    id_recepcion            INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_oc                   INT UNSIGNED    NOT NULL,
    fecha_recepcion         DATE            NOT NULL,
    tipo_recepcion          ENUM('completa','parcial') NOT NULL,
    notificado_inventario   TINYINT(1)      NOT NULL DEFAULT 0,
    observaciones           TEXT            NULL,
    activo                  TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion          DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion        VARCHAR(100)    NULL,
    fecha_modificacion      DATETIME        NULL,
    usuario_modificacion    VARCHAR(100)    NULL,
    fecha_eliminacion       DATETIME        NULL,
    eliminado_por           VARCHAR(100)    NULL,

    CONSTRAINT pk_recepciones       PRIMARY KEY (id_recepcion),
    CONSTRAINT fk_rec_oc            FOREIGN KEY (id_oc)
        REFERENCES ordenes_compra (id_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE INDEX idx_rec_oc             ON recepciones (id_oc);
CREATE INDEX idx_rec_notificado     ON recepciones (notificado_inventario);
CREATE INDEX idx_rec_fecha          ON recepciones (fecha_recepcion);

-- ------------------------------------------------------------
-- 1.7 detalle_recepcion
-- Diagrama de clases — DetalleRecepcion (sección d)
-- [FIX-3] Agregados fecha_eliminacion y eliminado_por (diagrama d / B.4)
-- ------------------------------------------------------------
CREATE TABLE detalle_recepcion (
    id_detalle_rec          INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_recepcion            INT UNSIGNED    NOT NULL,
    id_detalle_oc           INT UNSIGNED    NOT NULL,
    ref_mod_b_id_producto   INT UNSIGNED    NOT NULL,
    cantidad_recibida       INT             NOT NULL,
    activo                  TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion          DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion        VARCHAR(100)    NULL,
    fecha_eliminacion       DATETIME        NULL,
    eliminado_por           VARCHAR(100)    NULL,

    CONSTRAINT pk_detalle_rec       PRIMARY KEY (id_detalle_rec),
    CONSTRAINT fk_detrec_recepcion  FOREIGN KEY (id_recepcion)
        REFERENCES recepciones (id_recepcion)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_detrec_detoc      FOREIGN KEY (id_detalle_oc)
        REFERENCES detalle_orden_compra (id_detalle_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_detrec_cantidad  CHECK (cantidad_recibida > 0)
);

CREATE INDEX idx_detrec_recepcion   ON detalle_recepcion (id_recepcion);
CREATE INDEX idx_detrec_detoc       ON detalle_recepcion (id_detalle_oc);
CREATE INDEX idx_detrec_producto_b  ON detalle_recepcion (ref_mod_b_id_producto);

-- ------------------------------------------------------------
-- 1.8 facturas_proveedor
-- Diagrama de clases — FacturaProveedor <<Subject>> (sección d)
-- [FIX-1] num_autorizacion_retencion: VARCHAR(49) (B.4 y diagrama d)
-- [FIX-3] Agregados fecha_eliminacion y eliminado_por (diagrama d / B.4)
-- ------------------------------------------------------------
CREATE TABLE facturas_proveedor (
    id_factura_prov                 INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    numero_factura_proveedor        VARCHAR(20)     NOT NULL,
    numero_serie                    VARCHAR(7)      NOT NULL,
    id_proveedor                    INT UNSIGNED    NOT NULL,
    id_oc                           INT UNSIGNED    NOT NULL,
    id_recepcion                    INT UNSIGNED    NOT NULL,
    fecha_emision                   DATE            NOT NULL,
    base_imponible                  DECIMAL(12,2)   NOT NULL,
    monto_iva                       DECIMAL(12,2)   NOT NULL,
    total                           DECIMAL(12,2)   NOT NULL,
    codigo_sustento                 VARCHAR(2)      NOT NULL,
    tipo_bien_servicio              VARCHAR(10)     NULL,
    ref_mod_d_tarifa_id             INT UNSIGNED    NULL,
    estado                          ENUM('pendiente_retencion','retencion_generada','pagada_parcial','pagada','anulada')
                                                    NOT NULL DEFAULT 'pendiente_retencion',
    ref_mod_d_doc_id                INT UNSIGNED    NULL,
    -- [FIX-1] VARCHAR(49): longitud exacta SRI Ecuador (B.4 Convenciones)
    num_autorizacion_retencion      VARCHAR(49)     NULL,
    xml_retencion                   LONGTEXT        NULL,
    activo                          TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion                  DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion                VARCHAR(100)    NULL,
    fecha_modificacion              DATETIME        NULL,
    usuario_modificacion            VARCHAR(100)    NULL,
    fecha_eliminacion               DATETIME        NULL,
    eliminado_por                   VARCHAR(100)    NULL,

    CONSTRAINT pk_facturas_prov         PRIMARY KEY (id_factura_prov),
    CONSTRAINT uq_fp_numero             UNIQUE      (numero_factura_proveedor),
    CONSTRAINT fk_fp_proveedor          FOREIGN KEY (id_proveedor)
        REFERENCES proveedores (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fp_oc                 FOREIGN KEY (id_oc)
        REFERENCES ordenes_compra (id_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fp_recepcion          FOREIGN KEY (id_recepcion)
        REFERENCES recepciones (id_recepcion)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_fp_base              CHECK (base_imponible >= 0),
    CONSTRAINT chk_fp_iva               CHECK (monto_iva >= 0),
    CONSTRAINT chk_fp_total             CHECK (total >= 0)
);

CREATE INDEX idx_fp_oc                  ON facturas_proveedor (id_oc);
CREATE INDEX idx_fp_proveedor_estado    ON facturas_proveedor (id_proveedor, estado);
CREATE INDEX idx_fp_sustento            ON facturas_proveedor (codigo_sustento);
CREATE INDEX idx_fp_fecha               ON facturas_proveedor (fecha_emision);

-- ------------------------------------------------------------
-- 1.9 cuentas_por_pagar
-- Diagrama de clases — CuentaPorPagar (sección d)
-- [FIX-3] Agregados fecha_eliminacion y eliminado_por (diagrama d / B.4)
-- ------------------------------------------------------------
CREATE TABLE cuentas_por_pagar (
    id_cxp              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_proveedor        INT UNSIGNED    NOT NULL,
    id_factura_prov     INT UNSIGNED    NOT NULL,
    monto_original      DECIMAL(12,2)   NOT NULL,
    saldo_pendiente     DECIMAL(12,2)   NOT NULL,
    fecha_vencimiento   DATE            NOT NULL,
    fecha_programada    DATE            NULL,
    estado              ENUM('pendiente','pagada_parcial','pagada','vencida')
                                        NOT NULL DEFAULT 'pendiente',
    activo              TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion      DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion    VARCHAR(100)    NULL,
    fecha_modificacion  DATETIME        NULL,
    usuario_modificacion VARCHAR(100)   NULL,
    fecha_eliminacion   DATETIME        NULL,
    eliminado_por       VARCHAR(100)    NULL,

    CONSTRAINT pk_cxp               PRIMARY KEY (id_cxp),
    CONSTRAINT fk_cxp_proveedor     FOREIGN KEY (id_proveedor)
        REFERENCES proveedores (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_cxp_factura       FOREIGN KEY (id_factura_prov)
        REFERENCES facturas_proveedor (id_factura_prov)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_cxp_monto        CHECK (monto_original > 0),
    CONSTRAINT chk_cxp_saldo        CHECK (saldo_pendiente >= 0)
);

CREATE INDEX idx_cxp_factura            ON cuentas_por_pagar (id_factura_prov);
CREATE INDEX idx_cxp_proveedor_estado   ON cuentas_por_pagar (id_proveedor, estado);
CREATE INDEX idx_cxp_vencimiento        ON cuentas_por_pagar (fecha_vencimiento);
CREATE INDEX idx_cxp_programada         ON cuentas_por_pagar (fecha_programada);

-- ------------------------------------------------------------
-- 1.10 pagos_proveedor
-- Diagrama de clases — PagoProveedor (sección d)
-- [FIX-3] Agregados fecha_eliminacion y eliminado_por (diagrama d / B.4)
-- ------------------------------------------------------------
CREATE TABLE pagos_proveedor (
    id_pago             INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_cxp              INT UNSIGNED    NOT NULL,
    id_proveedor        INT UNSIGNED    NOT NULL,
    fecha_pago          DATE            NOT NULL,
    monto               DECIMAL(12,2)   NOT NULL,
    forma_pago          ENUM('transferencia','cheque','efectivo') NOT NULL,
    referencia          VARCHAR(100)    NULL,
    activo              TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion      DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion    VARCHAR(100)    NULL,
    fecha_eliminacion   DATETIME        NULL,
    eliminado_por       VARCHAR(100)    NULL,

    CONSTRAINT pk_pagos_prov        PRIMARY KEY (id_pago),
    CONSTRAINT fk_pago_cxp          FOREIGN KEY (id_cxp)
        REFERENCES cuentas_por_pagar (id_cxp)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_pago_proveedor    FOREIGN KEY (id_proveedor)
        REFERENCES proveedores (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_pago_monto       CHECK (monto > 0)
);

CREATE INDEX idx_pagos_cxp          ON pagos_proveedor (id_cxp);
CREATE INDEX idx_pagos_proveedor    ON pagos_proveedor (id_proveedor);
CREATE INDEX idx_pagos_fecha        ON pagos_proveedor (fecha_pago);

-- ============================================================
-- 2. FUNCIONES
-- ============================================================

DELIMITER $$

-- ------------------------------------------------------------
-- fn_calcular_fecha_vencimiento
-- Suma dias_credito del proveedor a la fecha de emisión.
-- NOT DETERMINISTIC: lee de la tabla proveedores.
-- ------------------------------------------------------------
CREATE FUNCTION fn_calcular_fecha_vencimiento(
    p_fecha_emision  DATE,
    p_id_proveedor   INT UNSIGNED
)
RETURNS DATE
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_dias INT DEFAULT 30;
    SELECT dias_credito INTO v_dias
    FROM   proveedores
    WHERE  id_proveedor = p_id_proveedor;
    RETURN DATE_ADD(p_fecha_emision, INTERVAL v_dias DAY);
END$$

-- ------------------------------------------------------------
-- fn_saldo_proveedor
-- Suma todos los saldo_pendiente de CxP activas del proveedor.
-- ------------------------------------------------------------
CREATE FUNCTION fn_saldo_proveedor(
    p_id_proveedor INT UNSIGNED
)
RETURNS DECIMAL(12,2)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_saldo DECIMAL(12,2) DEFAULT 0.00;
    SELECT COALESCE(SUM(saldo_pendiente), 0) INTO v_saldo
    FROM   cuentas_por_pagar
    WHERE  id_proveedor = p_id_proveedor
      AND  activo = 1
      AND  estado <> 'pagada';
    RETURN v_saldo;
END$$

-- ------------------------------------------------------------
-- fn_dias_vencimiento
-- Días restantes hasta vencimiento (negativo si ya venció).
-- [FIX-2] NOT DETERMINISTIC: invoca CURDATE() que cambia cada día.
-- ------------------------------------------------------------
CREATE FUNCTION fn_dias_vencimiento(
    p_fecha_vencimiento DATE
)
RETURNS INT
NOT DETERMINISTIC
NO SQL
BEGIN
    RETURN DATEDIFF(p_fecha_vencimiento, CURDATE());
END$$

-- ------------------------------------------------------------
-- fn_porcentaje_recepcion_oc
-- Calcula % de cantidad total solicitada efectivamente recibida.
-- ------------------------------------------------------------
CREATE FUNCTION fn_porcentaje_recepcion_oc(
    p_id_oc INT UNSIGNED
)
RETURNS DECIMAL(5,2)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_solicitado DECIMAL(12,2) DEFAULT 0;
    DECLARE v_recibido   DECIMAL(12,2) DEFAULT 0;

    SELECT COALESCE(SUM(d.cantidad_solicitada), 0) INTO v_solicitado
    FROM   detalle_orden_compra d
    WHERE  d.id_oc  = p_id_oc
      AND  d.activo = 1;

    SELECT COALESCE(SUM(dr.cantidad_recibida), 0) INTO v_recibido
    FROM   detalle_recepcion dr
    JOIN   recepciones r ON r.id_recepcion = dr.id_recepcion
    WHERE  r.id_oc   = p_id_oc
      AND  r.activo  = 1
      AND  dr.activo = 1;

    IF v_solicitado = 0 THEN
        RETURN 0.00;
    END IF;
    RETURN ROUND((v_recibido / v_solicitado) * 100, 2);
END$$

DELIMITER ;

-- ============================================================
-- 3. VISTAS
-- ============================================================
-- Sección de TRIGGERS eliminada (InformeSoftware v6, sección d).
-- Reacciones automáticas implementadas con patrón Observer en SPs:
--
--   Recepcion (Subject) → observadores:
--     · ActualizadorEstadoOrdenCompra  → sp_registrar_recepcion
--     · NotificadorInventarioB         → capa app vía IF-03 (notificado_inventario)
--
--   FacturaProveedor (Subject) → observadores:
--     · GeneradorCuentaPorPagarAutomatica → sp_ingresar_factura_proveedor
--     · EnviadorRetencionModuloD          → capa app vía IF-05 (asíncrono)
--
--   Cascade lógico → sp_eliminar_orden_logico (Sección 4).
-- ============================================================

-- ------------------------------------------------------------
-- vw_cuentas_pendientes   RF12
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_cuentas_pendientes AS
SELECT
    c.id_cxp,
    p.razon_social,
    p.identificacion,
    f.numero_factura_proveedor,
    f.numero_serie,
    c.monto_original,
    c.saldo_pendiente,
    c.fecha_vencimiento,
    c.fecha_programada,
    c.estado,
    fn_dias_vencimiento(c.fecha_vencimiento) AS dias_para_vencer
FROM  cuentas_por_pagar c
JOIN  proveedores        p ON p.id_proveedor    = c.id_proveedor
JOIN  facturas_proveedor f ON f.id_factura_prov = c.id_factura_prov
WHERE c.activo = 1
  AND c.estado <> 'pagada';

-- ------------------------------------------------------------
-- vw_pagos_por_vencer   RF10/CU-10  (horizonte 7 días)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_pagos_por_vencer AS
SELECT
    c.id_cxp,
    p.razon_social,
    p.identificacion,
    f.numero_factura_proveedor,
    c.saldo_pendiente,
    c.fecha_vencimiento,
    c.fecha_programada,
    fn_dias_vencimiento(c.fecha_vencimiento) AS dias_para_vencer
FROM  cuentas_por_pagar c
JOIN  proveedores        p ON p.id_proveedor    = c.id_proveedor
JOIN  facturas_proveedor f ON f.id_factura_prov = c.id_factura_prov
WHERE c.activo = 1
  AND c.estado IN ('pendiente','pagada_parcial')
  AND c.saldo_pendiente > 0
  AND fn_dias_vencimiento(c.fecha_vencimiento) BETWEEN 0 AND 7
ORDER BY dias_para_vencer ASC;

-- ------------------------------------------------------------
-- vw_estado_cuenta_proveedor   RF09/CU-09
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_estado_cuenta_proveedor AS
SELECT
    p.id_proveedor,
    p.razon_social,
    p.identificacion,
    f.numero_factura_proveedor,
    f.fecha_emision,
    f.total             AS monto_factura,
    c.fecha_vencimiento,
    c.fecha_programada,
    c.monto_original,
    c.saldo_pendiente,
    c.estado            AS estado_cxp,
    pp.id_pago,
    pp.fecha_pago,
    pp.monto            AS monto_pago,
    pp.forma_pago
FROM  proveedores        p
JOIN  facturas_proveedor f  ON f.id_proveedor    = p.id_proveedor
JOIN  cuentas_por_pagar  c  ON c.id_factura_prov = f.id_factura_prov
LEFT JOIN pagos_proveedor pp ON pp.id_cxp        = c.id_cxp AND pp.activo = 1
WHERE p.activo = 1
  AND f.activo = 1
  AND c.activo = 1;

-- ------------------------------------------------------------
-- vw_ordenes_pendientes_recepcion   RF11/CU-11
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ordenes_pendientes_recepcion AS
SELECT
    o.id_oc,
    o.numero_oc,
    p.razon_social,
    o.fecha_emision,
    o.fecha_entrega_esperada,
    o.estado,
    fn_porcentaje_recepcion_oc(o.id_oc)     AS porcentaje_recibido,
    DATEDIFF(CURDATE(), o.fecha_emision)     AS dias_desde_emision
FROM  ordenes_compra o
JOIN  proveedores    p ON p.id_proveedor = o.id_proveedor
WHERE o.activo = 1
  AND o.estado IN ('enviada','recibida_parcial');

-- ------------------------------------------------------------
-- vw_recepciones_pendientes_notificar
-- Recuperación ante fallos IF-03 → MOD-B (RNF02)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_recepciones_pendientes_notificar AS
SELECT
    r.id_recepcion,
    r.id_oc,
    r.fecha_recepcion,
    r.tipo_recepcion,
    dr.id_detalle_rec,
    dr.ref_mod_b_id_producto,
    dr.cantidad_recibida
FROM  recepciones       r
JOIN  detalle_recepcion dr ON dr.id_recepcion = r.id_recepcion
WHERE r.notificado_inventario = 0
  AND r.activo  = 1
  AND dr.activo = 1;

-- ============================================================
-- 4. PROCEDIMIENTOS ALMACENADOS
-- ============================================================

DELIMITER $$

-- ------------------------------------------------------------
-- sp_crear_orden_compra
-- RF02/RF15 / CU-02
-- Estado inicial 'enviada' (postcondición CU-02).
-- Actualiza solicitudes_compra en MOD-B si viene de IF-02.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_crear_orden_compra(
    IN p_id_proveedor    INT UNSIGNED,
    IN p_id_solicitud    INT UNSIGNED,
    IN p_items           JSON,
    IN p_fecha_entrega   DATE,
    IN p_observaciones   TEXT,
    IN p_usuario         VARCHAR(100)
)
BEGIN
    DECLARE v_id_oc      INT UNSIGNED;
    DECLARE v_numero_oc  VARCHAR(20);
    DECLARE v_total      DECIMAL(12,2) DEFAULT 0;
    DECLARE v_i          INT DEFAULT 0;
    DECLARE v_n          INT;
    DECLARE v_id_prod    INT UNSIGNED;
    DECLARE v_desc       VARCHAR(200);
    DECLARE v_cant       INT;
    DECLARE v_precio     DECIMAL(12,2);
    DECLARE v_subtotal   DECIMAL(12,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SET v_numero_oc = CONCAT('OC-', DATE_FORMAT(NOW(), '%Y%m'), '-', LPAD(FLOOR(RAND()*99999), 5, '0'));

    INSERT INTO ordenes_compra (
        numero_oc, id_proveedor, ref_mod_b_id_solicitud,
        fecha_emision, fecha_entrega_esperada, estado,
        observaciones, activo, fecha_creacion, usuario_creacion
    ) VALUES (
        v_numero_oc, p_id_proveedor, p_id_solicitud,
        CURDATE(), p_fecha_entrega, 'enviada',
        p_observaciones, 1, NOW(), p_usuario
    );

    SET v_id_oc = LAST_INSERT_ID();
    SET v_n     = JSON_LENGTH(p_items);

    WHILE v_i < v_n DO
        SET v_id_prod  = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].id_producto')));
        SET v_desc     = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].descripcion')));
        SET v_cant     = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].cantidad')));
        SET v_precio   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].precio')));
        SET v_subtotal = v_cant * v_precio;
        SET v_total    = v_total + v_subtotal;

        INSERT INTO detalle_orden_compra (
            id_oc, ref_mod_b_id_producto, descripcion_al_momento,
            cantidad_solicitada, precio_unitario_pactado, subtotal,
            activo, fecha_creacion, usuario_creacion
        ) VALUES (
            v_id_oc, v_id_prod, v_desc,
            v_cant, v_precio, v_subtotal,
            1, NOW(), p_usuario
        );

        SET v_i = v_i + 1;
    END WHILE;

    UPDATE ordenes_compra SET total_estimado = v_total WHERE id_oc = v_id_oc;

    IF p_id_solicitud IS NOT NULL THEN
        UPDATE modulo_b.solicitudes_compra
        SET    estado         = 'procesada',
               id_oc_generada = v_id_oc
        WHERE  id_solicitud   = p_id_solicitud;
    END IF;

    COMMIT;
    SELECT v_id_oc AS id_oc_creada, v_numero_oc AS numero_oc;
END$$

-- ------------------------------------------------------------
-- sp_registrar_recepcion
-- RF03/RF04/RF13 / CU-03 / CU-04
--
-- Patrón Observer — Recepcion como Subject (diagrama d):
--   · ActualizadorEstadoOrdenCompra → actualiza estado OC aquí
--   · NotificadorInventarioB        → notificado_inventario=0;
--     la capa app llama IF-03 y actualiza notificado_inventario=1
-- ------------------------------------------------------------
CREATE PROCEDURE sp_registrar_recepcion(
    IN p_id_oc          INT UNSIGNED,
    IN p_tipo           ENUM('completa','parcial'),
    IN p_items          JSON,
    IN p_observaciones  TEXT,
    IN p_usuario        VARCHAR(100)
)
BEGIN
    DECLARE v_id_rec INT UNSIGNED;
    DECLARE v_i      INT DEFAULT 0;
    DECLARE v_n      INT;
    DECLARE v_pct    DECIMAL(5,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    INSERT INTO recepciones (
        id_oc, fecha_recepcion, tipo_recepcion,
        notificado_inventario, observaciones,
        activo, fecha_creacion, usuario_creacion
    ) VALUES (
        p_id_oc, CURDATE(), p_tipo,
        0, p_observaciones,
        1, NOW(), p_usuario
    );

    SET v_id_rec = LAST_INSERT_ID();
    SET v_n      = JSON_LENGTH(p_items);

    WHILE v_i < v_n DO
        INSERT INTO detalle_recepcion (
            id_recepcion, id_detalle_oc, ref_mod_b_id_producto,
            cantidad_recibida, activo, fecha_creacion, usuario_creacion
        ) VALUES (
            v_id_rec,
            JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].id_detalle_oc'))),
            JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].id_producto'))),
            JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].cantidad_recibida'))),
            1, NOW(), p_usuario
        );
        SET v_i = v_i + 1;
    END WHILE;

    -- ── Observer: ActualizadorEstadoOrdenCompra ──────────────────────────
    SET v_pct = fn_porcentaje_recepcion_oc(p_id_oc);

    UPDATE ordenes_compra
    SET    estado               = CASE
                                    WHEN v_pct >= 100 THEN 'recibida_total'
                                    ELSE 'recibida_parcial'
                                  END,
           fecha_modificacion   = NOW(),
           usuario_modificacion = p_usuario
    WHERE  id_oc = p_id_oc;
    -- ─────────────────────────────────────────────────────────────────────

    COMMIT;
    SELECT v_id_rec AS id_recepcion_creada;
END$$

-- ------------------------------------------------------------
-- sp_generar_cuenta_por_pagar
-- RF06 / CU-06
-- Llamado por sp_ingresar_factura_proveedor como
-- GeneradorCuentaPorPagarAutomatica (patrón Observer).
-- ------------------------------------------------------------
CREATE PROCEDURE sp_generar_cuenta_por_pagar(
    IN p_id_factura_prov INT UNSIGNED
)
BEGIN
    DECLARE v_venc          DATE;
    DECLARE v_total         DECIMAL(12,2);
    DECLARE v_id_proveedor  INT UNSIGNED;
    DECLARE v_fecha_emision DATE;
    DECLARE v_usuario       VARCHAR(100);

    SELECT id_proveedor, total, fecha_emision, usuario_creacion
    INTO   v_id_proveedor, v_total, v_fecha_emision, v_usuario
    FROM   facturas_proveedor
    WHERE  id_factura_prov = p_id_factura_prov;

    SET v_venc = fn_calcular_fecha_vencimiento(v_fecha_emision, v_id_proveedor);

    INSERT INTO cuentas_por_pagar (
        id_proveedor, id_factura_prov,
        monto_original, saldo_pendiente,
        fecha_vencimiento, fecha_programada,
        estado, activo, fecha_creacion, usuario_creacion
    ) VALUES (
        v_id_proveedor, p_id_factura_prov,
        v_total, v_total,
        v_venc, NULL,
        'pendiente', 1, NOW(), v_usuario
    );
END$$

-- ------------------------------------------------------------
-- sp_ingresar_factura_proveedor
-- RF05/RF17 / CU-05
--
-- Patrón Observer — FacturaProveedor como Subject (diagrama d):
--   · GeneradorCuentaPorPagarAutomatica → CALL sp_generar_cuenta_por_pagar
--   · EnviadorRetencionModuloD → capa app vía IF-05 (asíncrono)
-- ------------------------------------------------------------
CREATE PROCEDURE sp_ingresar_factura_proveedor(
    IN p_numero_factura       VARCHAR(20),
    IN p_numero_serie         VARCHAR(7),
    IN p_codigo_sustento      VARCHAR(2),
    IN p_id_proveedor         INT UNSIGNED,
    IN p_id_oc                INT UNSIGNED,
    IN p_id_recepcion         INT UNSIGNED,
    IN p_base_imponible       DECIMAL(12,2),
    IN p_monto_iva            DECIMAL(12,2),
    IN p_tipo_bien_servicio   VARCHAR(10),
    IN p_ref_mod_d_tarifa_id  INT UNSIGNED,
    IN p_usuario              VARCHAR(100)
)
BEGIN
    DECLARE v_total      DECIMAL(12,2);
    DECLARE v_id_factura INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_total = p_base_imponible + p_monto_iva;

    START TRANSACTION;

    INSERT INTO facturas_proveedor (
        numero_factura_proveedor, numero_serie,
        id_proveedor, id_oc, id_recepcion,
        fecha_emision, base_imponible, monto_iva, total,
        codigo_sustento, tipo_bien_servicio, ref_mod_d_tarifa_id,
        estado, activo, fecha_creacion, usuario_creacion
    ) VALUES (
        p_numero_factura, p_numero_serie,
        p_id_proveedor, p_id_oc, p_id_recepcion,
        CURDATE(), p_base_imponible, p_monto_iva, v_total,
        p_codigo_sustento, p_tipo_bien_servicio, p_ref_mod_d_tarifa_id,
        'pendiente_retencion', 1, NOW(), p_usuario
    );

    SET v_id_factura = LAST_INSERT_ID();

    -- ── Observer: GeneradorCuentaPorPagarAutomatica (CU-06) ──────────────
    CALL sp_generar_cuenta_por_pagar(v_id_factura);
    -- ─────────────────────────────────────────────────────────────────────

    -- ── Observer: EnviadorRetencionModuloD (IF-05) ───────────────────────
    -- La capa de app envía los datos a MOD-D y al confirmar llama
    -- sp_actualizar_retencion_desde_modd con XML + numAutorizacion.
    -- ─────────────────────────────────────────────────────────────────────

    COMMIT;
    SELECT v_id_factura AS id_factura_creada;
END$$

-- ------------------------------------------------------------
-- sp_registrar_pago
-- RF07/RF08 / CU-07 + CU-08
-- SELECT con FOR UPDATE: evita race condition en pagos
-- concurrentes sobre el mismo saldo.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_registrar_pago(
    IN p_id_cxp      INT UNSIGNED,
    IN p_monto       DECIMAL(12,2),
    IN p_forma_pago  ENUM('transferencia','cheque','efectivo'),
    IN p_referencia  VARCHAR(100),
    IN p_usuario     VARCHAR(100)
)
BEGIN
    DECLARE v_saldo        DECIMAL(12,2);
    DECLARE v_nuevo_saldo  DECIMAL(12,2);
    DECLARE v_id_prov      INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT saldo_pendiente, id_proveedor
    INTO   v_saldo, v_id_prov
    FROM   cuentas_por_pagar
    WHERE  id_cxp  = p_id_cxp
      AND  activo  = 1
    FOR UPDATE;

    IF p_monto > v_saldo THEN
        ROLLBACK;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'El monto a pagar supera el saldo pendiente de la cuenta.';
    END IF;

    INSERT INTO pagos_proveedor (
        id_cxp, id_proveedor, fecha_pago,
        monto, forma_pago, referencia,
        activo, fecha_creacion, usuario_creacion
    ) VALUES (
        p_id_cxp, v_id_prov, CURDATE(),
        p_monto, p_forma_pago, p_referencia,
        1, NOW(), p_usuario
    );

    -- ── Observer: CU-08 Actualizar saldo/estado CxP ──────────────────────
    SET v_nuevo_saldo = v_saldo - p_monto;

    UPDATE cuentas_por_pagar
    SET    saldo_pendiente      = v_nuevo_saldo,
           estado               = CASE
                                    WHEN v_nuevo_saldo <= 0 THEN 'pagada'
                                    ELSE 'pagada_parcial'
                                  END,
           fecha_modificacion   = NOW(),
           usuario_modificacion = p_usuario
    WHERE  id_cxp = p_id_cxp;
    -- ─────────────────────────────────────────────────────────────────────

    COMMIT;
END$$

-- ------------------------------------------------------------
-- sp_programar_pago
-- RF — Programación de pagos
-- ------------------------------------------------------------
CREATE PROCEDURE sp_programar_pago(
    IN p_id_cxp          INT UNSIGNED,
    IN p_fecha_programada DATE,
    IN p_usuario          VARCHAR(100)
)
BEGIN
    IF p_fecha_programada < CURDATE() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La fecha programada no puede ser anterior a hoy.';
    END IF;

    UPDATE cuentas_por_pagar
    SET    fecha_programada     = p_fecha_programada,
           fecha_modificacion   = NOW(),
           usuario_modificacion = p_usuario
    WHERE  id_cxp  = p_id_cxp
      AND  activo  = 1;
END$$

-- ------------------------------------------------------------
-- sp_actualizar_retencion_desde_modd
-- RF17 — respuesta asíncrona de MOD-D (IF-05)
-- [FIX-1] p_num_autorizacion: VARCHAR(49) (B.4 y diagrama de clases)
-- ------------------------------------------------------------
CREATE PROCEDURE sp_actualizar_retencion_desde_modd(
    IN p_id_factura_prov  INT UNSIGNED,
    IN p_xml_retencion    LONGTEXT,
    IN p_num_autorizacion VARCHAR(49)
)
BEGIN
    UPDATE facturas_proveedor
    SET    xml_retencion              = p_xml_retencion,
           num_autorizacion_retencion = p_num_autorizacion,
           estado                     = 'retencion_generada',
           fecha_modificacion         = NOW()
    WHERE  id_factura_prov = p_id_factura_prov;
END$$

-- ------------------------------------------------------------
-- sp_eliminar_orden_logico
-- Borrado lógico en cascada: OC → detalle_oc → recepciones
-- → detalle_recepcion (B.4).
-- [FIX-5] Cascada extendida a recepciones y detalle_recepcion;
-- escribe fecha_eliminacion y eliminado_por en cada tabla.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_eliminar_orden_logico(
    IN p_id_oc   INT UNSIGNED,
    IN p_usuario VARCHAR(100)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- 1. detalle_recepcion vinculado a esta OC
    UPDATE detalle_recepcion dr
    JOIN   recepciones r ON r.id_recepcion = dr.id_recepcion
    SET    dr.activo            = 0,
           dr.fecha_eliminacion = NOW(),
           dr.eliminado_por     = p_usuario
    WHERE  r.id_oc   = p_id_oc
      AND  dr.activo = 1;

    -- 2. recepciones vinculadas a esta OC
    UPDATE recepciones
    SET    activo            = 0,
           fecha_eliminacion = NOW(),
           eliminado_por     = p_usuario
    WHERE  id_oc   = p_id_oc
      AND  activo  = 1;

    -- 3. detalle_orden_compra
    UPDATE detalle_orden_compra
    SET    activo            = 0,
           fecha_eliminacion = NOW(),
           eliminado_por     = p_usuario
    WHERE  id_oc   = p_id_oc
      AND  activo  = 1;

    -- 4. OC principal
    UPDATE ordenes_compra
    SET    activo               = 0,
           fecha_modificacion   = NOW(),
           usuario_modificacion = p_usuario,
           fecha_eliminacion    = NOW(),
           eliminado_por        = p_usuario
    WHERE  id_oc   = p_id_oc
      AND  activo  = 1;

    COMMIT;
END$$

-- ------------------------------------------------------------
-- sp_reporte_obligaciones_pendientes
-- RF12 / CU-12
-- ------------------------------------------------------------
CREATE PROCEDURE sp_reporte_obligaciones_pendientes(
    IN p_criterio  ENUM('proveedor','vencimiento','estado'),
    IN p_desde     DATE,
    IN p_hasta     DATE
)
BEGIN
    SELECT
        razon_social,
        identificacion,
        numero_factura_proveedor,
        numero_serie,
        monto_original,
        saldo_pendiente,
        fecha_vencimiento,
        fecha_programada,
        estado,
        dias_para_vencer
    FROM  vw_cuentas_pendientes
    WHERE fecha_vencimiento BETWEEN p_desde AND p_hasta
    ORDER BY
        CASE p_criterio
            WHEN 'proveedor'   THEN razon_social
            WHEN 'vencimiento' THEN CAST(dias_para_vencer AS CHAR)
            WHEN 'estado'      THEN estado
            ELSE razon_social
        END;
END$$

-- ------------------------------------------------------------
-- sp_estado_cuenta_proveedor
-- RF09/RF10 / CU-09
-- ------------------------------------------------------------
CREATE PROCEDURE sp_estado_cuenta_proveedor(
    IN p_id_proveedor INT UNSIGNED,
    IN p_desde        DATE,
    IN p_hasta        DATE
)
BEGIN
    SELECT *
    FROM   vw_estado_cuenta_proveedor
    WHERE  id_proveedor  = p_id_proveedor
      AND  fecha_emision BETWEEN p_desde AND p_hasta
    ORDER BY fecha_emision, id_pago;
END$$

-- ------------------------------------------------------------
-- sp_reintentar_notificaciones_modb
-- RNF02 — robustez ante fallos IF-03 → MOD-B
-- ------------------------------------------------------------
CREATE PROCEDURE sp_reintentar_notificaciones_modb()
BEGIN
    SELECT id_recepcion, id_oc, ref_mod_b_id_producto, cantidad_recibida
    FROM   vw_recepciones_pendientes_notificar;
END$$

-- ------------------------------------------------------------
-- sp_consultar_precio_costo_producto
-- RF16 / CU-14 — implementa ServicioConsultaCostosA (diagrama d)
-- Expone a MOD-A el precio de costo más reciente de un producto
-- (solo lectura, IF-01 / IC-A01).
-- [FIX-4] SP ausente en versiones anteriores.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_consultar_precio_costo_producto(
    IN p_ref_mod_b_id_producto INT UNSIGNED
)
BEGIN
    SELECT
        d.ref_mod_b_id_producto     AS id_producto,
        d.descripcion_al_momento    AS descripcion,
        d.precio_unitario_pactado   AS precio_costo,
        o.numero_oc,
        o.fecha_emision             AS fecha_oc,
        p.razon_social              AS proveedor
    FROM  detalle_orden_compra d
    JOIN  ordenes_compra       o ON o.id_oc        = d.id_oc
    JOIN  proveedores          p ON p.id_proveedor = o.id_proveedor
    WHERE d.ref_mod_b_id_producto = p_ref_mod_b_id_producto
      AND d.activo = 1
      AND o.activo = 1
      AND o.estado NOT IN ('borrador','anulada')
    ORDER BY o.fecha_emision DESC
    LIMIT 1;
END$$

-- ------------------------------------------------------------
-- sp_consultar_ultimo_costo_adquisicion
-- RF16 / CU-14 — implementa ServicioConsultaCostosA (diagrama d)
-- Historial de costos de adquisición para cálculo de márgenes
-- en MOD-A (IF-01).
-- [FIX-4] SP ausente en versiones anteriores.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_consultar_ultimo_costo_adquisicion(
    IN p_ref_mod_b_id_producto INT UNSIGNED,
    IN p_limite                INT
)
BEGIN
    SELECT
        d.ref_mod_b_id_producto     AS id_producto,
        d.descripcion_al_momento    AS descripcion,
        d.precio_unitario_pactado   AS precio_costo,
        d.cantidad_solicitada,
        o.numero_oc,
        o.fecha_emision             AS fecha_oc,
        p.razon_social              AS proveedor
    FROM  detalle_orden_compra d
    JOIN  ordenes_compra       o ON o.id_oc        = d.id_oc
    JOIN  proveedores          p ON p.id_proveedor = o.id_proveedor
    WHERE d.ref_mod_b_id_producto = p_ref_mod_b_id_producto
      AND d.activo = 1
      AND o.activo = 1
      AND o.estado NOT IN ('borrador','anulada')
    ORDER BY o.fecha_emision DESC
    LIMIT p_limite;
END$$

DELIMITER ;
