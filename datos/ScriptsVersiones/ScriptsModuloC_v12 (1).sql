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
--  • sp_crear_orden_compra: estado inicial 'emitida' (CU-02).
--  • sp_registrar_pago: SELECT dentro de START TRANSACTION con FOR UPDATE.
--  • fn_calcular_fecha_vencimiento: NOT DETERMINISTIC (lee tabla).
--
--  v4 (revisión minuciosa contra InformeSoftware v6):
--  • [FIX-1] num_autorizacion_retencion: VARCHAR(49) según B.4 y diagrama
--    de clases (antes VARCHAR(50)). Corregido en tabla y SP.
--  • [FIX-2] fn_dias_vencimiento: NOT DETERMINISTIC (usa CURDATE();
--    antes marcada DETERMINISTIC, lo cual es incorrecto).
--  • [FIX-3] Agregados fecha_eliminacion y eliminado_por a TODAS las
--    entidades del diagrama de clases (sección d) que los requerían.
--  • [FIX-4] Agregados sp_consultar_precio_costo_producto y
--    sp_consultar_ultimo_costo_adquisicion implementando la interfaz
--    ServicioConsultaCostosA (CU-14 / RF16 / IF-01).
--  • [FIX-5] sp_eliminar_orden_logico: cascada lógica extendida a
--    Recepcion y DetalleRecepcion.
--
--  v5 (ajuste de nombres de tablas a PascalCase/singular):
--  • Todos los nombres de tabla normalizados al estándar del equipo.
--  • Estado 'enviada' → 'emitida' en ENUM, SP e INSERT (B.4 vs informe).
--  • Recepcion: eliminadas fecha_modificacion y usuario_modificacion
--    (columnas huérfanas — ningún SP las actualizaba).
--
--  v6 (alineación completa con veredicto técnico):
--  • [FIX-6]  CU-17: FacturaProveedor permite factura sin OC/recepcion
--    (id_oc y id_recepcion ahora NULL); agregados factura_excepcional,
--    motivo_excepcion, usuario_autorizador, fecha_autorizacion.
--    sp_ingresar_factura_proveedor acepta p_id_oc / p_id_recepcion NULL.
--  • [FIX-7]  CuentaPorPagar: UNIQUE(id_factura_prov) garantiza 1-a-1
--    con FacturaProveedor (diagrama de clases sección d).
--    sp_generar_cuenta_por_pagar valida duplicado antes de insertar.
--  • [FIX-8]  sp_registrar_recepcion: validación de cantidad pendiente
--    por ítem antes de insertar DetalleRecepcion (RF03/CU-03).
--  • [FIX-9]  sp_marcar_recepcion_notificada: cierra el ciclo CU-04 /
--    marcarInventarioNotificado(); agrega fecha_notificacion_inventario
--    y usuario_notificacion en Recepcion.
--  • [FIX-10] vw_pagos_por_vencer: reemplaza fn_dias_vencimiento() en
--    WHERE por fecha_vencimiento BETWEEN CURDATE() AND +7 días.
--    Agregado índice compuesto idx_cxp_alertas.
--  • [FIX-11] LogSincronizacion: tabla para RNF02 (fallos IF-03).
--  • [FIX-12] BitacoraAuditoria: tabla para RNF04 (operaciones financieras).
--    Registros de auditoría en sp_ingresar_factura_proveedor,
--    sp_registrar_pago, sp_generar_cuenta_por_pagar y
--    sp_actualizar_retencion_desde_modd.
--  • [FIX-13] FacturaProveedor.estado reducido a estados tributarios:
--    'pendiente_retencion','retencion_generada','anulada'.
--    Estados de pago (pagada_parcial/pagada) quedan solo en CuentaPorPagar.
--  • [FIX-14] modulo_b.solicitudes_compra documentado explícitamente
--    como tabla de interfaz IF-02 (no tabla interna de MOD-B).
--
--  v7 (alineación con contratos de integración entre módulos):
--  • [FIX-15] DetalleOrdenCompra: agregados campos de snapshot del
--    catálogo MOD-B: codigo_producto_al_momento, unidad_medida_al_momento.
--    sp_crear_orden_compra lee precio_costo (alias del contrato IF-04) y
--    unidad_medida del JSON de ítems (RF14 / IF-04).
--  • [FIX-16] Vistas de compatibilidad snake_case para cumplir contratos
--    entre módulos (sin reescribir tablas ni SPs internos).
--  • [FIX-17] sp_crear_orden_compra: eliminado UPDATE directo a
--    modulo_b.solicitudes_compra; reemplazado por INSERT en
--    LogSincronizacion estado='pendiente' para que la capa app
--    complete la integración IF-02 (coherencia arquitectónica).
--  • [FIX-18] vw_facturas_pendientes_retencion: vista de payload IF-05
--    con nombres de campo alineados al contrato con MOD-D.
--    sp_actualizar_retencion_desde_modd: parámetros renombrados a
--    p_xmlRetencion / p_numAutorizacion (contrato IF-05).
--  • [FIX-19] sp_consultar_precio_costo_producto y
--    sp_consultar_ultimo_costo_adquisicion: respuesta controlada cuando
--    no hay costo registrado (evita resultado vacío ambiguo para MOD-A).
--  • [FIX-20] Sección de pruebas de integración: llamadas de ejemplo
--    con IDs acordados (productos 1–20, interfaces IF-01/IF-03/IF-04).
--
--  v8 (correcciones técnicas según revisión de requerimientos):
--  • [FIX-21] sp_ingresar_factura_proveedor: validación que factura
--    regular (no excepcional) requiere id_oc e id_recepcion (CU-05).
--  • [FIX-22] sp_ingresar_factura_proveedor: validación de coherencia
--    entre OC, recepción y proveedor; estado de OC debe ser
--    recibida_parcial o recibida_total antes de facturar.
--  • [FIX-23] sp_ingresar_factura_proveedor: validación de que el monto
--    total no supere el pendiente de facturación de la OC.
--  • [FIX-24] sp_registrar_recepcion: SELECT de DetalleOrdenCompra
--    incluye AND id_oc = p_id_oc para evitar detalle de otra OC;
--    señal explícita si detalle no pertenece a la OC.
--  • [FIX-25] sp_registrar_recepcion: validación de estado de la OC
--    antes de insertar recepción (solo emitida o recibida_parcial).
--  • [FIX-26] CuentaPorPagar: agregado campo fecha_cancelacion DATE NULL.
--    sp_registrar_pago: actualiza fecha_cancelacion cuando saldo = 0 (CU-08).
--  • [FIX-27] sp_ingresar_factura_proveedor: comentario RNF03 aclarando
--    que validación de rol Administrador queda en capa de aplicación.
--  • [FIX-28] sp_alertar_pagos_por_vencer(p_dias INT): nuevo SP con
--    horizonte configurable para RF10; vw_pagos_por_vencer conserva
--    7 días como valor predeterminado.
--  • [FIX-29] sp_registrar_error_sincronizacion: nuevo SP genérico para
--    registrar fallos IF-03, IF-05, IF-06 en LogSincronizacion (RNF02).
--
--  v9 (correcciones técnicas de robustez e integridad):
--  • [FIX-30] sp_registrar_recepcion: reinicio explícito de
--    v_cant_solicitada, v_cant_recibida_prev y v_id_producto_real
--    al inicio de cada iteración del WHILE para evitar retención
--    de valores de iteraciones anteriores (MySQL SELECT INTO).
--  • [FIX-31] sp_registrar_recepcion: ref_mod_b_id_producto se obtiene
--    desde DetalleOrdenCompra (fuente de verdad), no del JSON de entrada.
--    Evita inconsistencia si la capa app envía un id_producto distinto.
--  • [FIX-32] sp_ingresar_factura_proveedor: nueva validación que exige
--    id_oc e id_recepcion NULL cuando factura_excepcional = 1 (CU-17).
--  • [FIX-33] sp_ingresar_factura_proveedor: validación de monto pendiente
--    movida dentro de la transacción con SELECT ... FOR UPDATE en
--    OrdenCompra para evitar race condition entre registros concurrentes.
--  • [FIX-34] sp_actualizar_cuentas_vencidas: nuevo SP que marca como
--    'vencida' las CxP cuya fecha_vencimiento ya pasó y tienen saldo
--    pendiente. Ejecutar periódicamente desde la capa de aplicación (RF12).
--  • [FIX-35] sp_registrar_pago: validación explícita de existencia de
--    la cuenta (v_saldo IS NULL) con mensaje claro antes de operar.
--  • [FIX-36] sp_generar_cuenta_por_pagar: validación explícita de
--    existencia de la factura antes de leer sus datos.
--  • [FIX-37] sp_reporte_obligaciones_pendientes: criterio 'vencimiento'
--    ahora ordena por fecha_vencimiento (DATE) en lugar de
--    CAST(dias_para_vencer AS CHAR), eliminando orden lexicográfico incorrecto.
--
--  v10 (ajustes finales de robustez y cobertura de auditoría):
--  • [FIX-38] sp_crear_orden_compra: validación de proveedor activo
--    antes de START TRANSACTION (precondición CU-02).
--  • [FIX-39] sp_crear_orden_compra: validación de JSON de ítems no
--    vacío; impide crear OC sin productos (CU-02).
--  • [FIX-40] sp_registrar_recepcion: validación de JSON de ítems no
--    vacío; impide recepción sin detalles (CU-03).
--  • [FIX-41] sp_actualizar_retencion_desde_modd: validación previa
--    y WHERE restringido a activo=1 AND estado='pendiente_retencion';
--    evita reprocesar facturas anuladas o ya procesadas.
--  • [FIX-42] sp_actualizar_cuentas_vencidas: registra en BitacoraAuditoria
--    la cantidad de cuentas marcadas como vencidas por ejecución batch (RNF04).
--  • [FIX-43] sp_programar_pago: registra en BitacoraAuditoria el cambio
--    de fecha_programada con valor anterior y nuevo (RNF04).
--  • [FIX-44] sp_ingresar_factura_proveedor: comentario RNF03 ampliado
--    para dejar claro que la validación de rol Administrador es
--    responsabilidad exclusiva de la capa de aplicación.
--
--  v11 (ajustes finales de robustez):
--  • [FIX-45] sp_programar_pago: validación explícita de existencia de
--    la cuenta tras SELECT INTO (v_fecha_anterior IS NULL → SIGNAL).
--  • [FIX-46] sp_programar_pago: WHERE del UPDATE restringido a cuentas
--    con saldo_pendiente > 0 y estado IN (pendiente, pagada_parcial,
--    vencida); impide programar pagos sobre cuentas ya pagadas.
--  • [FIX-47] sp_generar_cuenta_por_pagar: validación adicional que
--    rechaza facturas en estado 'anulada' aunque estén activas.
--  • [FIX-48] sp_marcar_recepcion_notificada: WHERE incluye
--    notificado_inventario = 0 y ROW_COUNT() = 0 lanza SIGNAL si
--    la recepción no existe, está inactiva o ya fue notificada.
--  • [FIX-49] sp_consultar_precio_costo_producto y
--    sp_consultar_ultimo_costo_adquisicion: filtro cambiado de
--    NOT IN ('borrador','anulada') a IN ('recibida_parcial',
--    'recibida_total'); el costo de adquisición corresponde a
--    mercadería efectivamente recibida, no solo pactada.
--
--  v12 (corrección de lógica en sp_programar_pago y sp_registrar_pago):
--  • [FIX-50] sp_programar_pago: la validación de existencia ya no
--    depende de v_fecha_anterior IS NULL, lo que confundía una cuenta
--    recién creada (fecha_programada = NULL por diseño) con una cuenta
--    inexistente. Ahora se usa NOT EXISTS separado sobre id_cxp + activo
--    + saldo_pendiente > 0 + estado IN (...) como única fuente de verdad.
--    SELECT fecha_programada se hace después, solo para auditoría.
--  • [FIX-51] sp_programar_pago: validación explícita de que
--    p_fecha_programada no sea NULL (parámetro obligatorio).
--  • [FIX-52] sp_registrar_pago: validación explícita de p_monto > 0
--    antes del INSERT, para devolver un mensaje claro en lugar de
--    depender únicamente del CHECK constraint de la tabla.
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
-- 1.1 Proveedor  (tabla raíz del módulo)
-- Diagrama de clases — clase abstracta Proveedor (sección d)
-- ------------------------------------------------------------
CREATE TABLE Proveedor (
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

CREATE INDEX idx_prov_activo       ON Proveedor (activo);
CREATE INDEX idx_prov_tipo         ON Proveedor (tipo_proveedor);
CREATE INDEX idx_prov_calificacion ON Proveedor (calificacion);

-- ------------------------------------------------------------
-- 1.2 ProveedorPersonaNatural  (subtipo de Proveedor)
-- ------------------------------------------------------------
CREATE TABLE ProveedorPersonaNatural (
    id_proveedor    INT UNSIGNED NOT NULL,
    cedula          VARCHAR(10)  NOT NULL,

    CONSTRAINT pk_ppn            PRIMARY KEY (id_proveedor),
    CONSTRAINT uq_ppn_cedula     UNIQUE      (cedula),
    CONSTRAINT fk_ppn_proveedor  FOREIGN KEY (id_proveedor)
        REFERENCES Proveedor (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ------------------------------------------------------------
-- 1.3 ProveedorPersonaJuridica  (subtipo de Proveedor)
-- ------------------------------------------------------------
CREATE TABLE ProveedorPersonaJuridica (
    id_proveedor        INT UNSIGNED    NOT NULL,
    razon_social        VARCHAR(200)    NOT NULL,
    nombre_comercial    VARCHAR(200)    NULL,

    CONSTRAINT pk_ppj            PRIMARY KEY (id_proveedor),
    CONSTRAINT fk_ppj_proveedor  FOREIGN KEY (id_proveedor)
        REFERENCES Proveedor (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ------------------------------------------------------------
-- 1.4 OrdenCompra
-- ------------------------------------------------------------
CREATE TABLE OrdenCompra (
    id_oc                   INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    numero_oc               VARCHAR(20)     NOT NULL,
    id_proveedor            INT UNSIGNED    NOT NULL,
    ref_mod_b_id_solicitud  INT UNSIGNED    NULL,
    fecha_emision           DATE            NOT NULL,
    fecha_entrega_esperada  DATE            NULL,
    estado                  ENUM('borrador','emitida','recibida_parcial','recibida_total','anulada')
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
        REFERENCES Proveedor (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_oc_total             CHECK (total_estimado IS NULL OR total_estimado >= 0),
    CONSTRAINT chk_oc_fechas            CHECK (fecha_entrega_esperada IS NULL OR fecha_entrega_esperada >= fecha_emision)
);

CREATE INDEX idx_oc_fecha_emision   ON OrdenCompra (fecha_emision);
CREATE INDEX idx_oc_proveedor       ON OrdenCompra (id_proveedor);
CREATE INDEX idx_oc_estado          ON OrdenCompra (estado);
CREATE INDEX idx_oc_solicitud_b     ON OrdenCompra (ref_mod_b_id_solicitud);

-- ------------------------------------------------------------
-- 1.5 DetalleOrdenCompra
-- [FIX-15] Agregados codigo_producto_al_momento y
--          unidad_medida_al_momento como snapshot del catálogo
--          MOD-B al momento de emitir la OC (RF14 / IF-04).
-- ------------------------------------------------------------
CREATE TABLE DetalleOrdenCompra (
    id_detalle_oc               INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_oc                       INT UNSIGNED    NOT NULL,
    ref_mod_b_id_producto       INT UNSIGNED    NOT NULL,
    -- [FIX-15] Snapshot del catálogo MOD-B en el momento de la OC
    codigo_producto_al_momento  VARCHAR(50)     NULL,
    descripcion_al_momento      VARCHAR(200)    NOT NULL,
    unidad_medida_al_momento    VARCHAR(30)     NULL,
    cantidad_solicitada         INT             NOT NULL,
    -- precio_unitario_pactado = precio_costo del contrato IF-04
    precio_unitario_pactado     DECIMAL(12,2)   NOT NULL,
    subtotal                    DECIMAL(12,2)   NOT NULL,
    activo                      TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion              DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion            VARCHAR(100)    NULL,
    fecha_eliminacion           DATETIME        NULL,
    eliminado_por               VARCHAR(100)    NULL,

    CONSTRAINT pk_detalle_oc            PRIMARY KEY (id_detalle_oc),
    CONSTRAINT fk_detoc_oc              FOREIGN KEY (id_oc)
        REFERENCES OrdenCompra (id_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_detoc_cantidad       CHECK (cantidad_solicitada > 0),
    CONSTRAINT chk_detoc_precio         CHECK (precio_unitario_pactado >= 0),
    CONSTRAINT chk_detoc_subtotal       CHECK (subtotal >= 0)
);

CREATE INDEX idx_detoc_oc           ON DetalleOrdenCompra (id_oc);
CREATE INDEX idx_detoc_producto_b   ON DetalleOrdenCompra (ref_mod_b_id_producto);

-- ------------------------------------------------------------
-- 1.6 Recepcion
-- [FIX-9] Agregados fecha_notificacion_inventario y
--         usuario_notificacion para cerrar ciclo CU-04.
-- ------------------------------------------------------------
CREATE TABLE Recepcion (
    id_recepcion                    INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_oc                           INT UNSIGNED    NOT NULL,
    fecha_recepcion                 DATE            NOT NULL,
    tipo_recepcion                  ENUM('completa','parcial') NOT NULL,
    notificado_inventario           TINYINT(1)      NOT NULL DEFAULT 0,
    fecha_notificacion_inventario   DATETIME        NULL,
    usuario_notificacion            VARCHAR(100)    NULL,
    observaciones                   TEXT            NULL,
    activo                          TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion                  DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion                VARCHAR(100)    NULL,
    fecha_eliminacion               DATETIME        NULL,
    eliminado_por                   VARCHAR(100)    NULL,

    CONSTRAINT pk_recepciones       PRIMARY KEY (id_recepcion),
    CONSTRAINT fk_rec_oc            FOREIGN KEY (id_oc)
        REFERENCES OrdenCompra (id_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE INDEX idx_rec_oc             ON Recepcion (id_oc);
CREATE INDEX idx_rec_notificado     ON Recepcion (notificado_inventario);
CREATE INDEX idx_rec_fecha          ON Recepcion (fecha_recepcion);

-- ------------------------------------------------------------
-- 1.7 DetalleRecepcion
-- ------------------------------------------------------------
CREATE TABLE DetalleRecepcion (
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
        REFERENCES Recepcion (id_recepcion)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_detrec_detoc      FOREIGN KEY (id_detalle_oc)
        REFERENCES DetalleOrdenCompra (id_detalle_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_detrec_cantidad  CHECK (cantidad_recibida > 0)
);

CREATE INDEX idx_detrec_recepcion   ON DetalleRecepcion (id_recepcion);
CREATE INDEX idx_detrec_detoc       ON DetalleRecepcion (id_detalle_oc);
CREATE INDEX idx_detrec_producto_b  ON DetalleRecepcion (ref_mod_b_id_producto);

-- ------------------------------------------------------------
-- 1.8 FacturaProveedor
-- [FIX-1]  num_autorizacion_retencion: VARCHAR(49)
-- [FIX-6]  id_oc / id_recepcion NULL → soporta CU-17
-- [FIX-13] estado solo tributario: pendiente_retencion,
--          retencion_generada, anulada
-- ------------------------------------------------------------
CREATE TABLE FacturaProveedor (
    id_factura_prov                 INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    numero_factura_proveedor        VARCHAR(20)     NOT NULL,
    numero_serie                    VARCHAR(7)      NOT NULL,
    id_proveedor                    INT UNSIGNED    NOT NULL,
    -- [FIX-6] NULL si es factura excepcional (CU-17)
    id_oc                           INT UNSIGNED    NULL,
    id_recepcion                    INT UNSIGNED    NULL,
    fecha_emision                   DATE            NOT NULL,
    base_imponible                  DECIMAL(12,2)   NOT NULL,
    monto_iva                       DECIMAL(12,2)   NOT NULL,
    total                           DECIMAL(12,2)   NOT NULL,
    codigo_sustento                 VARCHAR(2)      NOT NULL,
    tipo_bien_servicio              VARCHAR(10)     NULL,
    ref_mod_d_tarifa_id             INT UNSIGNED    NULL,
    -- [FIX-13] Solo estados tributarios; pagada_parcial/pagada → CuentaPorPagar
    estado                          ENUM('pendiente_retencion','retencion_generada','anulada')
                                                    NOT NULL DEFAULT 'pendiente_retencion',
    ref_mod_d_doc_id                INT UNSIGNED    NULL,
    -- [FIX-1] VARCHAR(49): longitud exacta SRI Ecuador
    num_autorizacion_retencion      VARCHAR(49)     NULL,
    xml_retencion                   LONGTEXT        NULL,
    -- [FIX-6] Campos de autorización para facturas excepcionales (CU-17)
    factura_excepcional             TINYINT(1)      NOT NULL DEFAULT 0,
    motivo_excepcion                VARCHAR(300)    NULL,
    usuario_autorizador             VARCHAR(100)    NULL,
    fecha_autorizacion              DATETIME        NULL,
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
        REFERENCES Proveedor (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fp_oc                 FOREIGN KEY (id_oc)
        REFERENCES OrdenCompra (id_oc)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fp_recepcion          FOREIGN KEY (id_recepcion)
        REFERENCES Recepcion (id_recepcion)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_fp_base              CHECK (base_imponible >= 0),
    CONSTRAINT chk_fp_iva               CHECK (monto_iva >= 0),
    CONSTRAINT chk_fp_total             CHECK (total >= 0),
    CONSTRAINT chk_fp_excepcion         CHECK (
        factura_excepcional = 0
        OR (motivo_excepcion IS NOT NULL AND usuario_autorizador IS NOT NULL)
    )
);

CREATE INDEX idx_fp_oc                  ON FacturaProveedor (id_oc);
CREATE INDEX idx_fp_proveedor_estado    ON FacturaProveedor (id_proveedor, estado);
CREATE INDEX idx_fp_sustento            ON FacturaProveedor (codigo_sustento);
CREATE INDEX idx_fp_fecha               ON FacturaProveedor (fecha_emision);

-- ------------------------------------------------------------
-- 1.9 CuentaPorPagar
-- [FIX-7] UNIQUE(id_factura_prov) → relación 1-a-1 con FacturaProveedor
-- ------------------------------------------------------------
CREATE TABLE CuentaPorPagar (
    id_cxp              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    id_proveedor        INT UNSIGNED    NOT NULL,
    id_factura_prov     INT UNSIGNED    NOT NULL,
    monto_original      DECIMAL(12,2)   NOT NULL,
    saldo_pendiente     DECIMAL(12,2)   NOT NULL,
    fecha_vencimiento   DATE            NOT NULL,
    fecha_programada    DATE            NULL,
    estado              ENUM('pendiente','pagada_parcial','pagada','vencida')
                                        NOT NULL DEFAULT 'pendiente',
    fecha_cancelacion   DATE            NULL,
    activo              TINYINT(1)      NOT NULL DEFAULT 1,
    fecha_creacion      DATETIME        NOT NULL DEFAULT NOW(),
    usuario_creacion    VARCHAR(100)    NULL,
    fecha_modificacion  DATETIME        NULL,
    usuario_modificacion VARCHAR(100)   NULL,
    fecha_eliminacion   DATETIME        NULL,
    eliminado_por       VARCHAR(100)    NULL,

    CONSTRAINT pk_cxp               PRIMARY KEY (id_cxp),
    -- [FIX-7] Garantiza 1 factura = 1 cuenta por pagar
    CONSTRAINT uq_cxp_factura       UNIQUE      (id_factura_prov),
    CONSTRAINT fk_cxp_proveedor     FOREIGN KEY (id_proveedor)
        REFERENCES Proveedor (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_cxp_factura       FOREIGN KEY (id_factura_prov)
        REFERENCES FacturaProveedor (id_factura_prov)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_cxp_monto        CHECK (monto_original > 0),
    CONSTRAINT chk_cxp_saldo        CHECK (saldo_pendiente >= 0)
);

CREATE INDEX idx_cxp_factura            ON CuentaPorPagar (id_factura_prov);
CREATE INDEX idx_cxp_proveedor_estado   ON CuentaPorPagar (id_proveedor, estado);
CREATE INDEX idx_cxp_vencimiento        ON CuentaPorPagar (fecha_vencimiento);
CREATE INDEX idx_cxp_programada         ON CuentaPorPagar (fecha_programada);
-- [FIX-10] Índice compuesto para vw_pagos_por_vencer sin función en WHERE
CREATE INDEX idx_cxp_alertas            ON CuentaPorPagar (activo, estado, fecha_vencimiento, saldo_pendiente);

-- ------------------------------------------------------------
-- 1.10 PagoProveedor
-- ------------------------------------------------------------
CREATE TABLE PagoProveedor (
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
        REFERENCES CuentaPorPagar (id_cxp)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_pago_proveedor    FOREIGN KEY (id_proveedor)
        REFERENCES Proveedor (id_proveedor)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_pago_monto       CHECK (monto > 0)
);

CREATE INDEX idx_pagos_cxp          ON PagoProveedor (id_cxp);
CREATE INDEX idx_pagos_proveedor    ON PagoProveedor (id_proveedor);
CREATE INDEX idx_pagos_fecha        ON PagoProveedor (fecha_pago);

-- ------------------------------------------------------------
-- 1.11 LogSincronizacion
-- [FIX-11] RNF02: fallos de comunicación entre módulos.
-- [FIX-17] También usado para cola IF-02 (solicitudes MOD-B).
-- ------------------------------------------------------------
CREATE TABLE LogSincronizacion (
    id_log          INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    modulo_destino  VARCHAR(20)     NOT NULL,
    interfaz        VARCHAR(20)     NOT NULL,
    id_referencia   INT UNSIGNED    NULL,
    estado          ENUM('pendiente','exitoso','fallido') NOT NULL DEFAULT 'pendiente',
    mensaje_error   TEXT            NULL,
    fecha_registro  DATETIME        NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_log_sinc PRIMARY KEY (id_log)
);

CREATE INDEX idx_log_interfaz ON LogSincronizacion (interfaz, estado);
CREATE INDEX idx_log_fecha    ON LogSincronizacion (fecha_registro);

-- ------------------------------------------------------------
-- 1.12 BitacoraAuditoria
-- [FIX-12] RNF04: operaciones financieras sensibles.
-- ------------------------------------------------------------
CREATE TABLE BitacoraAuditoria (
    id_auditoria    INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    tabla_afectada  VARCHAR(100)    NOT NULL,
    operacion       VARCHAR(20)     NOT NULL,
    id_registro     INT UNSIGNED    NOT NULL,
    usuario         VARCHAR(100)    NULL,
    valor_anterior  JSON            NULL,
    valor_nuevo     JSON            NULL,
    fecha_evento    DATETIME        NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_bitacora PRIMARY KEY (id_auditoria)
);

CREATE INDEX idx_bit_tabla   ON BitacoraAuditoria (tabla_afectada, operacion);
CREATE INDEX idx_bit_fecha   ON BitacoraAuditoria (fecha_evento);
CREATE INDEX idx_bit_usuario ON BitacoraAuditoria (usuario);

-- ============================================================
-- 2. FUNCIONES
-- ============================================================

DELIMITER $$

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
    FROM   Proveedor
    WHERE  id_proveedor = p_id_proveedor;
    RETURN DATE_ADD(p_fecha_emision, INTERVAL v_dias DAY);
END$$

CREATE FUNCTION fn_saldo_proveedor(
    p_id_proveedor INT UNSIGNED
)
RETURNS DECIMAL(12,2)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_saldo DECIMAL(12,2) DEFAULT 0.00;
    SELECT COALESCE(SUM(saldo_pendiente), 0) INTO v_saldo
    FROM   CuentaPorPagar
    WHERE  id_proveedor = p_id_proveedor
      AND  activo = 1
      AND  estado <> 'pagada';
    RETURN v_saldo;
END$$

-- [FIX-2] NOT DETERMINISTIC: usa CURDATE() que cambia cada día.
CREATE FUNCTION fn_dias_vencimiento(
    p_fecha_vencimiento DATE
)
RETURNS INT
NOT DETERMINISTIC
NO SQL
BEGIN
    RETURN DATEDIFF(p_fecha_vencimiento, CURDATE());
END$$

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
    FROM   DetalleOrdenCompra d
    WHERE  d.id_oc  = p_id_oc
      AND  d.activo = 1;

    SELECT COALESCE(SUM(dr.cantidad_recibida), 0) INTO v_recibido
    FROM   DetalleRecepcion dr
    JOIN   Recepcion r ON r.id_recepcion = dr.id_recepcion
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
-- Reacciones automáticas — patrón Observer en SPs:
--   Recepcion (Subject):
--     · ActualizadorEstadoOrdenCompra  → sp_registrar_recepcion
--     · NotificadorInventarioB         → capa app IF-03 → sp_marcar_recepcion_notificada
--   FacturaProveedor (Subject):
--     · GeneradorCuentaPorPagarAutomatica → sp_ingresar_factura_proveedor
--     · EnviadorRetencionModuloD          → capa app IF-05 (asíncrono)
--   Cascade lógico → sp_eliminar_orden_logico
--
-- Integración MOD-D (IF-05/IF-06):
--   La consulta IF-06 (tarifas IVA/retenciones) y el envío IF-05
--   son responsabilidad de la capa de aplicación. La BD registra
--   los datos tributarios recibidos y actualiza la factura cuando
--   MOD-D devuelve la retención vía sp_actualizar_retencion_desde_modd.
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
FROM  CuentaPorPagar c
JOIN  Proveedor        p ON p.id_proveedor    = c.id_proveedor
JOIN  FacturaProveedor f ON f.id_factura_prov = c.id_factura_prov
WHERE c.activo = 1
  AND c.estado <> 'pagada';

-- ------------------------------------------------------------
-- vw_pagos_por_vencer   RF10/CU-10  (horizonte 7 días)
-- [FIX-10] fecha_vencimiento BETWEEN para usar idx_cxp_alertas.
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
FROM  CuentaPorPagar c
JOIN  Proveedor        p ON p.id_proveedor    = c.id_proveedor
JOIN  FacturaProveedor f ON f.id_factura_prov = c.id_factura_prov
WHERE c.activo = 1
  AND c.estado IN ('pendiente','pagada_parcial')
  AND c.saldo_pendiente > 0
  AND c.fecha_vencimiento BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL 7 DAY)
ORDER BY c.fecha_vencimiento ASC;

-- EXPLAIN de referencia (ejecutar en producción para validar índice):
-- EXPLAIN SELECT c.id_cxp, c.saldo_pendiente, c.fecha_vencimiento
-- FROM CuentaPorPagar c
-- WHERE c.activo = 1
--   AND c.estado IN ('pendiente','pagada_parcial')
--   AND c.saldo_pendiente > 0
--   AND c.fecha_vencimiento BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL 7 DAY);

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
FROM  Proveedor        p
JOIN  FacturaProveedor f  ON f.id_proveedor    = p.id_proveedor
JOIN  CuentaPorPagar  c  ON c.id_factura_prov = f.id_factura_prov
LEFT JOIN PagoProveedor pp ON pp.id_cxp        = c.id_cxp AND pp.activo = 1
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
FROM  OrdenCompra o
JOIN  Proveedor    p ON p.id_proveedor = o.id_proveedor
WHERE o.activo = 1
  AND o.estado IN ('emitida','recibida_parcial');

-- ------------------------------------------------------------
-- vw_recepciones_pendientes_notificar
-- RNF02 — cola de reintento para IF-03 → MOD-B
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
FROM  Recepcion       r
JOIN  DetalleRecepcion dr ON dr.id_recepcion = r.id_recepcion
WHERE r.notificado_inventario = 0
  AND r.activo  = 1
  AND dr.activo = 1;

-- ------------------------------------------------------------
-- vw_facturas_pendientes_retencion
-- [FIX-18] Payload IF-05 para MOD-D. Nombres de columna alineados
--          al contrato: idFactura, rucProveedor, baseImponible, etc.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_facturas_pendientes_retencion AS
SELECT
    f.id_factura_prov       AS idFactura,
    p.identificacion        AS rucProveedor,
    p.tipo_proveedor        AS tipoProveedor,
    f.base_imponible        AS baseImponible,
    f.monto_iva             AS iva,
    f.tipo_bien_servicio    AS tipoBienServicio,
    f.codigo_sustento       AS codigoSustento,
    f.fecha_emision         AS fecha
FROM  FacturaProveedor f
JOIN  Proveedor        p ON p.id_proveedor = f.id_proveedor
WHERE f.estado = 'pendiente_retencion'
  AND f.activo = 1;

-- ------------------------------------------------------------
-- [FIX-16] Vistas de compatibilidad snake_case
-- Permiten que contratos y acuerdos entre módulos usen los
-- nombres de BD convencionales sin romper el diseño PascalCase.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW proveedores            AS SELECT * FROM Proveedor;
CREATE OR REPLACE VIEW ordenes_compra         AS SELECT * FROM OrdenCompra;
CREATE OR REPLACE VIEW detalle_orden_compra   AS SELECT * FROM DetalleOrdenCompra;
CREATE OR REPLACE VIEW recepciones            AS SELECT * FROM Recepcion;
CREATE OR REPLACE VIEW detalle_recepcion      AS SELECT * FROM DetalleRecepcion;
CREATE OR REPLACE VIEW facturas_proveedor     AS SELECT * FROM FacturaProveedor;
CREATE OR REPLACE VIEW cuentas_por_pagar      AS SELECT * FROM CuentaPorPagar;
CREATE OR REPLACE VIEW pagos_proveedor        AS SELECT * FROM PagoProveedor;

-- ============================================================
-- 4. PROCEDIMIENTOS ALMACENADOS
-- ============================================================

DELIMITER $$

-- ------------------------------------------------------------
-- sp_crear_orden_compra
-- RF02/RF15 / CU-02
-- Estado inicial 'emitida' (postcondición CU-02).
--
-- [FIX-15] JSON de ítems usa precio_costo (nombre del contrato
--          IF-04) y unidad_medida como snapshot del catálogo MOD-B.
--          precio_costo → precio_unitario_pactado internamente.
--
-- [FIX-17] Se elimina el UPDATE directo a modulo_b.solicitudes_compra.
--          Se registra un LogSincronizacion estado='pendiente' para
--          que la capa de aplicación complete la integración IF-02.
--          Esto es coherente con la arquitectura de interfaces
--          contractuales del informe.
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
    DECLARE v_codigo     VARCHAR(50);
    DECLARE v_desc       VARCHAR(200);
    DECLARE v_unidad     VARCHAR(30);
    DECLARE v_cant       INT;
    DECLARE v_precio     DECIMAL(12,2);
    DECLARE v_subtotal   DECIMAL(12,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- [3.1] Validar que el proveedor existe y está activo (precondición CU-02)
    IF NOT EXISTS (
        SELECT 1 FROM Proveedor
        WHERE  id_proveedor = p_id_proveedor AND activo = 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'El proveedor no existe o está inactivo.';
    END IF;

    -- [3.2] Validar que el JSON de ítems no esté vacío (CU-02 exige al menos un producto)
    IF JSON_LENGTH(p_items) IS NULL OR JSON_LENGTH(p_items) = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La orden de compra debe tener al menos un ítem.';
    END IF;

    START TRANSACTION;

    SET v_numero_oc = CONCAT('OC-', DATE_FORMAT(NOW(), '%Y%m'), '-', LPAD(FLOOR(RAND()*99999), 5, '0'));

    INSERT INTO OrdenCompra (
        numero_oc, id_proveedor, ref_mod_b_id_solicitud,
        fecha_emision, fecha_entrega_esperada, estado,
        observaciones, activo, fecha_creacion, usuario_creacion
    ) VALUES (
        v_numero_oc, p_id_proveedor, p_id_solicitud,
        CURDATE(), p_fecha_entrega, 'emitida',
        p_observaciones, 1, NOW(), p_usuario
    );

    SET v_id_oc = LAST_INSERT_ID();
    SET v_n     = JSON_LENGTH(p_items);

    WHILE v_i < v_n DO
        SET v_id_prod  = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].id_producto')));
        -- [FIX-15] Snapshot del catálogo MOD-B
        SET v_codigo   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].codigo_producto')));
        SET v_desc     = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].descripcion')));
        SET v_unidad   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].unidad_medida')));
        SET v_cant     = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].cantidad')));
        -- [FIX-15] precio_costo es el nombre del contrato IF-04
        SET v_precio   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].precio_costo')));
        SET v_subtotal = v_cant * v_precio;
        SET v_total    = v_total + v_subtotal;

        INSERT INTO DetalleOrdenCompra (
            id_oc, ref_mod_b_id_producto,
            codigo_producto_al_momento, descripcion_al_momento, unidad_medida_al_momento,
            cantidad_solicitada, precio_unitario_pactado, subtotal,
            activo, fecha_creacion, usuario_creacion
        ) VALUES (
            v_id_oc, v_id_prod,
            v_codigo, v_desc, v_unidad,
            v_cant, v_precio, v_subtotal,
            1, NOW(), p_usuario
        );

        SET v_i = v_i + 1;
    END WHILE;

    UPDATE OrdenCompra SET total_estimado = v_total WHERE id_oc = v_id_oc;

    -- [FIX-17] IF-02: encolar notificación a MOD-B vía LogSincronizacion.
    -- La capa de aplicación lee este registro y actualiza solicitudes_compra
    -- mediante la interfaz IF-02, manteniendo independencia entre módulos.
    IF p_id_solicitud IS NOT NULL THEN
        INSERT INTO LogSincronizacion (modulo_destino, interfaz, id_referencia, estado, fecha_registro)
        VALUES ('MOD-B', 'IF-02', p_id_solicitud, 'pendiente', NOW());
    END IF;

    COMMIT;
    SELECT v_id_oc AS id_oc_creada, v_numero_oc AS numero_oc;
END$$

-- ------------------------------------------------------------
-- sp_registrar_recepcion
-- RF03/RF04/RF13 / CU-03 / CU-04
-- [FIX-8] Valida cantidad pendiente antes de insertar DetRec.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_registrar_recepcion(
    IN p_id_oc          INT UNSIGNED,
    IN p_tipo           ENUM('completa','parcial'),
    IN p_items          JSON,
    IN p_observaciones  TEXT,
    IN p_usuario        VARCHAR(100)
)
BEGIN
    DECLARE v_id_rec             INT UNSIGNED;
    DECLARE v_i                  INT DEFAULT 0;
    DECLARE v_n                  INT;
    DECLARE v_pct                DECIMAL(5,2);
    DECLARE v_id_detalle_oc      INT UNSIGNED;
    DECLARE v_cant_recibida      INT;
    DECLARE v_cant_solicitada    INT;
    DECLARE v_cant_recibida_prev DECIMAL(12,2);
    DECLARE v_cant_pendiente     DECIMAL(12,2);
    -- [2.3] id_producto obtenido desde DetalleOrdenCompra, no del JSON
    DECLARE v_id_producto_real   INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- [CU-03 / Corrección 5] Validar que la OC existe, está activa y en estado permitido
    IF NOT EXISTS (
        SELECT 1 FROM OrdenCompra
        WHERE  id_oc  = p_id_oc
          AND  activo = 1
          AND  estado IN ('emitida', 'recibida_parcial')
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La orden no está en un estado válido para registrar recepción.';
    END IF;

    -- [3.3] Validar que el JSON de ítems no esté vacío (CU-03 exige al menos un detalle recibido)
    IF JSON_LENGTH(p_items) IS NULL OR JSON_LENGTH(p_items) = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La recepción debe tener al menos un detalle recibido.';
    END IF;

    INSERT INTO Recepcion (
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
        SET v_id_detalle_oc = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].id_detalle_oc')));
        SET v_cant_recibida = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].cantidad_recibida')));

        -- [FIX-8] Validar cantidad pendiente por ítem (RF03/CU-03)
        -- [Corrección 4] Validar que el detalle pertenece a esta OC
        -- [2.1] Reiniciar variables para evitar retención de valor de iteración anterior
        SET v_cant_solicitada    = NULL;
        SET v_cant_recibida_prev = NULL;
        -- [2.3] Reiniciar también el producto real
        SET v_id_producto_real   = NULL;

        -- [2.3] Obtener cantidad_solicitada Y ref_mod_b_id_producto desde la tabla,
        --       no confiar en el id_producto enviado por el JSON
        SELECT cantidad_solicitada, ref_mod_b_id_producto
        INTO   v_cant_solicitada, v_id_producto_real
        FROM   DetalleOrdenCompra
        WHERE  id_detalle_oc = v_id_detalle_oc
          AND  id_oc         = p_id_oc
          AND  activo        = 1;

        IF v_cant_solicitada IS NULL THEN
            ROLLBACK;
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'El detalle de ítem no pertenece a la orden de compra indicada.';
        END IF;

        SELECT COALESCE(SUM(dr.cantidad_recibida), 0) INTO v_cant_recibida_prev
        FROM   DetalleRecepcion dr
        JOIN   Recepcion r ON r.id_recepcion = dr.id_recepcion
        WHERE  dr.id_detalle_oc = v_id_detalle_oc
          AND  dr.activo = 1 AND r.activo = 1;

        SET v_cant_pendiente = v_cant_solicitada - v_cant_recibida_prev;

        IF v_cant_recibida > v_cant_pendiente THEN
            ROLLBACK;
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'La cantidad recibida supera la cantidad pendiente de recepción.';
        END IF;

        INSERT INTO DetalleRecepcion (
            id_recepcion, id_detalle_oc, ref_mod_b_id_producto,
            cantidad_recibida, activo, fecha_creacion, usuario_creacion
        ) VALUES (
            v_id_rec,
            v_id_detalle_oc,
            -- [2.3] Se usa el id_producto leído desde DetalleOrdenCompra, no del JSON
            v_id_producto_real,
            v_cant_recibida,
            1, NOW(), p_usuario
        );

        SET v_i = v_i + 1;
    END WHILE;

    -- ── Observer: ActualizadorEstadoOrdenCompra ──────────────────────────
    SET v_pct = fn_porcentaje_recepcion_oc(p_id_oc);
    UPDATE OrdenCompra
    SET    estado               = CASE WHEN v_pct >= 100 THEN 'recibida_total' ELSE 'recibida_parcial' END,
           fecha_modificacion   = NOW(),
           usuario_modificacion = p_usuario
    WHERE  id_oc = p_id_oc;
    -- ─────────────────────────────────────────────────────────────────────

    COMMIT;
    SELECT v_id_rec AS id_recepcion_creada;
END$$

-- ------------------------------------------------------------
-- sp_marcar_recepcion_notificada
-- RF13 / CU-04 — cierra ciclo marcarInventarioNotificado()
-- [FIX-9] La capa app llama este SP después de confirmar IF-03.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_marcar_recepcion_notificada(
    IN p_id_recepcion   INT UNSIGNED,
    IN p_usuario        VARCHAR(100)
)
BEGIN
    UPDATE Recepcion
    SET    notificado_inventario         = 1,
           fecha_notificacion_inventario = NOW(),
           usuario_notificacion          = p_usuario
    WHERE  id_recepcion = p_id_recepcion
      AND  activo = 1
      AND  notificado_inventario = 0;

    -- [3.4] Validar que el UPDATE afectó exactamente una fila
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La recepción no existe, está inactiva o ya fue notificada al inventario.';
    END IF;
END$$

-- ------------------------------------------------------------
-- sp_generar_cuenta_por_pagar
-- RF06 / CU-06 — Observer GeneradorCuentaPorPagarAutomatica
-- [FIX-7]  Valida 1-a-1 antes de insertar.
-- [FIX-12] Auditoría RNF04.
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
    DECLARE v_id_cxp        INT UNSIGNED;

    -- [FIX-7] Validar relación 1-a-1
    IF EXISTS (
        SELECT 1 FROM CuentaPorPagar
        WHERE  id_factura_prov = p_id_factura_prov AND activo = 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La factura ya tiene una cuenta por pagar asociada.';
    END IF;

    -- [2.7] Validar que la factura existe y está activa
    IF NOT EXISTS (
        SELECT 1 FROM FacturaProveedor
        WHERE  id_factura_prov = p_id_factura_prov AND activo = 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La factura no existe o está inactiva.';
    END IF;

    -- [3.3] Validar que la factura no esté anulada
    IF EXISTS (
        SELECT 1 FROM FacturaProveedor
        WHERE  id_factura_prov = p_id_factura_prov AND estado = 'anulada'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No se puede generar cuenta por pagar para una factura anulada.';
    END IF;

    SELECT id_proveedor, total, fecha_emision, usuario_creacion
    INTO   v_id_proveedor, v_total, v_fecha_emision, v_usuario
    FROM   FacturaProveedor
    WHERE  id_factura_prov = p_id_factura_prov;

    SET v_venc = fn_calcular_fecha_vencimiento(v_fecha_emision, v_id_proveedor);

    INSERT INTO CuentaPorPagar (
        id_proveedor, id_factura_prov,
        monto_original, saldo_pendiente,
        fecha_vencimiento, fecha_programada,
        estado, activo, fecha_creacion, usuario_creacion
    ) VALUES (
        v_id_proveedor, p_id_factura_prov,
        v_total, v_total, v_venc, NULL,
        'pendiente', 1, NOW(), v_usuario
    );

    SET v_id_cxp = LAST_INSERT_ID();

    -- [FIX-12] Auditoría RNF04
    INSERT INTO BitacoraAuditoria (tabla_afectada, operacion, id_registro, usuario, valor_nuevo, fecha_evento)
    VALUES ('CuentaPorPagar', 'INSERT', v_id_cxp, v_usuario,
            JSON_OBJECT('id_factura_prov', p_id_factura_prov, 'monto_original', v_total,
                        'fecha_vencimiento', v_venc, 'estado', 'pendiente'),
            NOW());
END$$

-- ------------------------------------------------------------
-- sp_ingresar_factura_proveedor
-- RF05/RF17 / CU-05 / CU-17
-- [FIX-6]  p_id_oc / p_id_recepcion NULL para facturas excepcionales.
-- [FIX-12] Auditoría RNF04.
-- [RNF03]  Control de acceso por roles: la validación de que
--          p_usuario_autorizador tenga rol Administrador NO se
--          realiza en base de datos. Este SP únicamente registra
--          el usuario autorizador recibido como parámetro.
--          La verificación de rol es responsabilidad exclusiva de
--          la capa de aplicación / componente de control de acceso,
--          tal como establece el diseño arquitectónico del módulo.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_ingresar_factura_proveedor(
    IN p_numero_factura         VARCHAR(20),
    IN p_numero_serie           VARCHAR(7),
    IN p_codigo_sustento        VARCHAR(2),
    IN p_id_proveedor           INT UNSIGNED,
    IN p_id_oc                  INT UNSIGNED,   -- NULL si factura excepcional (CU-17)
    IN p_id_recepcion           INT UNSIGNED,   -- NULL si factura excepcional (CU-17)
    IN p_base_imponible         DECIMAL(12,2),
    IN p_monto_iva              DECIMAL(12,2),
    IN p_tipo_bien_servicio     VARCHAR(10),
    IN p_ref_mod_d_tarifa_id    INT UNSIGNED,
    IN p_factura_excepcional    TINYINT(1),
    IN p_motivo_excepcion       VARCHAR(300),   -- obligatorio si excepcional
    IN p_usuario_autorizador    VARCHAR(100),   -- obligatorio si excepcional
    IN p_usuario                VARCHAR(100)
)
BEGIN
    DECLARE v_total      DECIMAL(12,2);
    DECLARE v_id_factura INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- [FIX-6] Validar autorización en facturas excepcionales
    IF p_factura_excepcional = 1 AND (p_motivo_excepcion IS NULL OR p_usuario_autorizador IS NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Una factura excepcional requiere motivo y usuario autorizador.';
    END IF;

    -- [2.2 / CU-17] Factura excepcional no debe tener OC ni recepción asociada
    IF p_factura_excepcional = 1 AND (p_id_oc IS NOT NULL OR p_id_recepcion IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Una factura excepcional no debe tener orden de compra ni recepción asociada.';
    END IF;

    -- [CU-05] Validar que factura regular tiene OC y recepción asociadas
    IF p_factura_excepcional = 0 AND (p_id_oc IS NULL OR p_id_recepcion IS NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Una factura regular requiere orden de compra y recepción asociadas.';
    END IF;

    -- [CU-05] Validar coherencia entre OC, recepción y proveedor
    IF p_factura_excepcional = 0 THEN
        IF NOT EXISTS (
            SELECT 1
            FROM   OrdenCompra oc
            JOIN   Recepcion r ON r.id_oc = oc.id_oc
            WHERE  oc.id_oc          = p_id_oc
              AND  r.id_recepcion    = p_id_recepcion
              AND  oc.id_proveedor   = p_id_proveedor
              AND  oc.estado         IN ('recibida_parcial', 'recibida_total')
              AND  oc.activo         = 1
              AND  r.activo          = 1
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'La orden de compra y la recepción no corresponden al proveedor indicado o la orden no está en estado válido para facturar.';
        END IF;
    END IF;

    SET v_total = p_base_imponible + p_monto_iva;

    START TRANSACTION;

    -- [2.4 / CU-05] Validar monto pendiente dentro de la transacción con bloqueo
    --               para evitar race condition entre registros concurrentes de facturas
    IF p_factura_excepcional = 0 THEN
        BEGIN
            DECLARE v_total_estimado       DECIMAL(12,2) DEFAULT 0;
            DECLARE v_total_facturado_prev DECIMAL(12,2) DEFAULT 0;

            SELECT COALESCE(total_estimado, 0) INTO v_total_estimado
            FROM   OrdenCompra WHERE id_oc = p_id_oc
            FOR UPDATE;

            SELECT COALESCE(SUM(total), 0) INTO v_total_facturado_prev
            FROM   FacturaProveedor
            WHERE  id_oc = p_id_oc AND activo = 1 AND estado <> 'anulada';

            IF v_total_facturado_prev + v_total > v_total_estimado THEN
                ROLLBACK;
                SIGNAL SQLSTATE '45000'
                    SET MESSAGE_TEXT = 'El monto de la factura supera el valor pendiente de facturación de la orden de compra.';
            END IF;
        END;
    END IF;

    INSERT INTO FacturaProveedor (
        numero_factura_proveedor, numero_serie,
        id_proveedor, id_oc, id_recepcion,
        fecha_emision, base_imponible, monto_iva, total,
        codigo_sustento, tipo_bien_servicio, ref_mod_d_tarifa_id,
        estado,
        factura_excepcional, motivo_excepcion,
        usuario_autorizador, fecha_autorizacion,
        activo, fecha_creacion, usuario_creacion
    ) VALUES (
        p_numero_factura, p_numero_serie,
        p_id_proveedor, p_id_oc, p_id_recepcion,
        CURDATE(), p_base_imponible, p_monto_iva, v_total,
        p_codigo_sustento, p_tipo_bien_servicio, p_ref_mod_d_tarifa_id,
        'pendiente_retencion',
        p_factura_excepcional, p_motivo_excepcion,
        CASE WHEN p_factura_excepcional = 1 THEN p_usuario_autorizador ELSE NULL END,
        CASE WHEN p_factura_excepcional = 1 THEN NOW() ELSE NULL END,
        1, NOW(), p_usuario
    );

    SET v_id_factura = LAST_INSERT_ID();

    -- [FIX-12] Auditoría RNF04
    INSERT INTO BitacoraAuditoria (tabla_afectada, operacion, id_registro, usuario, valor_nuevo, fecha_evento)
    VALUES ('FacturaProveedor', 'INSERT', v_id_factura, p_usuario,
            JSON_OBJECT('numero_factura', p_numero_factura, 'total', v_total,
                        'excepcional', p_factura_excepcional, 'estado', 'pendiente_retencion'),
            NOW());

    -- ── Observer: GeneradorCuentaPorPagarAutomatica (CU-06) ──────────────
    CALL sp_generar_cuenta_por_pagar(v_id_factura);

    -- ── Observer: EnviadorRetencionModuloD (IF-05) ───────────────────────
    -- La capa app consulta vw_facturas_pendientes_retencion y envía
    -- el payload a MOD-D. Al confirmar, llama sp_actualizar_retencion_desde_modd.
    -- ─────────────────────────────────────────────────────────────────────

    COMMIT;
    SELECT v_id_factura AS id_factura_creada;
END$$

-- ------------------------------------------------------------
-- sp_registrar_pago
-- RF07/RF08 / CU-07 + CU-08
-- FOR UPDATE: evita race condition en pagos concurrentes.
-- [FIX-12] Auditoría RNF04.
-- [FIX-52] Validación explícita de p_monto > 0.
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
    DECLARE v_id_pago      INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- [FIX-52] Validar monto positivo antes de iniciar la transacción;
    --          da un mensaje explícito en lugar de dejar fallar el CHECK constraint.
    IF p_monto IS NULL OR p_monto <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'El monto del pago debe ser mayor que cero.';
    END IF;

    START TRANSACTION;

    SELECT saldo_pendiente, id_proveedor
    INTO   v_saldo, v_id_prov
    FROM   CuentaPorPagar
    WHERE  id_cxp = p_id_cxp AND activo = 1
    FOR UPDATE;

    -- [2.6] Validar que la cuenta existe y está activa
    IF v_saldo IS NULL THEN
        ROLLBACK;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La cuenta por pagar no existe o está inactiva.';
    END IF;

    IF p_monto > v_saldo THEN
        ROLLBACK;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'El monto a pagar supera el saldo pendiente de la cuenta.';
    END IF;

    INSERT INTO PagoProveedor (
        id_cxp, id_proveedor, fecha_pago,
        monto, forma_pago, referencia,
        activo, fecha_creacion, usuario_creacion
    ) VALUES (
        p_id_cxp, v_id_prov, CURDATE(),
        p_monto, p_forma_pago, p_referencia,
        1, NOW(), p_usuario
    );

    SET v_id_pago     = LAST_INSERT_ID();
    SET v_nuevo_saldo = v_saldo - p_monto;

    UPDATE CuentaPorPagar
    SET    saldo_pendiente      = v_nuevo_saldo,
           estado               = CASE WHEN v_nuevo_saldo <= 0 THEN 'pagada' ELSE 'pagada_parcial' END,
           fecha_cancelacion    = CASE WHEN v_nuevo_saldo <= 0 THEN CURDATE() ELSE fecha_cancelacion END,
           fecha_modificacion   = NOW(),
           usuario_modificacion = p_usuario
    WHERE  id_cxp = p_id_cxp;

    -- [FIX-12] Auditoría RNF04
    INSERT INTO BitacoraAuditoria (tabla_afectada, operacion, id_registro, usuario, valor_anterior, valor_nuevo, fecha_evento)
    VALUES ('PagoProveedor', 'INSERT', v_id_pago, p_usuario,
            JSON_OBJECT('saldo_anterior', v_saldo),
            JSON_OBJECT('monto_pagado', p_monto, 'saldo_nuevo', v_nuevo_saldo, 'forma_pago', p_forma_pago),
            NOW());

    COMMIT;
END$$

-- ------------------------------------------------------------
-- sp_programar_pago
-- [FIX-50] Existencia validada con NOT EXISTS explícito; el SELECT
--          de fecha_programada ocurre después, solo para auditoría.
--          Esto corrige el falso positivo cuando la cuenta existe
--          pero aún no tiene fecha programada (NULL por diseño).
-- [FIX-51] Validación explícita de p_fecha_programada NOT NULL.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_programar_pago(
    IN p_id_cxp          INT UNSIGNED,
    IN p_fecha_programada DATE,
    IN p_usuario          VARCHAR(100)
)
BEGIN
    DECLARE v_fecha_anterior DATE;

    -- [FIX-51] La fecha programada es un parámetro obligatorio
    IF p_fecha_programada IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La fecha programada es obligatoria.';
    END IF;

    IF p_fecha_programada < CURDATE() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La fecha programada no puede ser anterior a hoy.';
    END IF;

    -- [FIX-50] Validar existencia, actividad, saldo y estado en una sola consulta.
    --          NO se usa v_fecha_anterior IS NULL como proxy de existencia,
    --          porque fecha_programada = NULL es el estado normal de una
    --          cuenta recién creada que aún no tiene pago programado.
    IF NOT EXISTS (
        SELECT 1
        FROM   CuentaPorPagar
        WHERE  id_cxp          = p_id_cxp
          AND  activo          = 1
          AND  saldo_pendiente > 0
          AND  estado          IN ('pendiente', 'pagada_parcial', 'vencida')
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No se puede programar pago: la cuenta no existe, está inactiva, ya está pagada o no tiene saldo pendiente.';
    END IF;

    -- [FIX-50] Leer fecha_programada anterior solo para auditoría,
    --          una vez confirmado que la cuenta es válida y operable.
    SELECT fecha_programada INTO v_fecha_anterior
    FROM   CuentaPorPagar
    WHERE  id_cxp = p_id_cxp AND activo = 1;

    UPDATE CuentaPorPagar
    SET    fecha_programada     = p_fecha_programada,
           fecha_modificacion   = NOW(),
           usuario_modificacion = p_usuario
    WHERE  id_cxp = p_id_cxp AND activo = 1;

    -- [FIX-43] Auditoría RNF04: cambio de fecha de pago programada
    INSERT INTO BitacoraAuditoria (tabla_afectada, operacion, id_registro, usuario, valor_anterior, valor_nuevo, fecha_evento)
    VALUES ('CuentaPorPagar', 'PROGRAMAR_PAGO', p_id_cxp, p_usuario,
            JSON_OBJECT('fecha_programada_anterior', v_fecha_anterior),
            JSON_OBJECT('fecha_programada_nueva', p_fecha_programada),
            NOW());
END$$

-- ------------------------------------------------------------
-- sp_actualizar_retencion_desde_modd
-- RF17 — respuesta asíncrona de MOD-D (IF-05)
-- [FIX-18] Parámetros renombrados para alinear con contrato IF-05:
--          p_xmlRetencion → xml_retencion
--          p_numAutorizacion → num_autorizacion_retencion
-- [FIX-12] Auditoría RNF04.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_actualizar_retencion_desde_modd(
    IN p_id_factura_prov  INT UNSIGNED,
    IN p_xmlRetencion     LONGTEXT,       -- xmlRetencion del contrato IF-05
    IN p_numAutorizacion  VARCHAR(49)     -- numAutorizacion del contrato IF-05
)
BEGIN
    -- [3.4] Solo actualizar si la factura está activa y pendiente de retención;
    --       evita reprocesar una factura anulada o ya con retención generada
    IF NOT EXISTS (
        SELECT 1 FROM FacturaProveedor
        WHERE  id_factura_prov = p_id_factura_prov
          AND  activo = 1
          AND  estado = 'pendiente_retencion'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La factura no existe, está inactiva o ya tiene retención generada.';
    END IF;

    UPDATE FacturaProveedor
    SET    xml_retencion              = p_xmlRetencion,
           num_autorizacion_retencion = p_numAutorizacion,
           estado                     = 'retencion_generada',
           fecha_modificacion         = NOW()
    WHERE  id_factura_prov = p_id_factura_prov
      AND  activo          = 1
      AND  estado          = 'pendiente_retencion';

    -- [FIX-12] Auditoría RNF04
    INSERT INTO BitacoraAuditoria (tabla_afectada, operacion, id_registro, usuario, valor_nuevo, fecha_evento)
    VALUES ('FacturaProveedor', 'UPDATE', p_id_factura_prov, 'modd_interfaz',
            JSON_OBJECT('estado', 'retencion_generada', 'numAutorizacion', p_numAutorizacion),
            NOW());
END$$

-- ------------------------------------------------------------
-- sp_eliminar_orden_logico
-- Borrado lógico en cascada: OC → DetalleOC → Recepcion → DetRec
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

    UPDATE DetalleRecepcion dr
    JOIN   Recepcion r ON r.id_recepcion = dr.id_recepcion
    SET    dr.activo = 0, dr.fecha_eliminacion = NOW(), dr.eliminado_por = p_usuario
    WHERE  r.id_oc = p_id_oc AND dr.activo = 1;

    UPDATE Recepcion
    SET    activo = 0, fecha_eliminacion = NOW(), eliminado_por = p_usuario
    WHERE  id_oc = p_id_oc AND activo = 1;

    UPDATE DetalleOrdenCompra
    SET    activo = 0, fecha_eliminacion = NOW(), eliminado_por = p_usuario
    WHERE  id_oc = p_id_oc AND activo = 1;

    UPDATE OrdenCompra
    SET    activo = 0, fecha_modificacion = NOW(), usuario_modificacion = p_usuario,
           fecha_eliminacion = NOW(), eliminado_por = p_usuario
    WHERE  id_oc = p_id_oc AND activo = 1;

    COMMIT;
END$$

-- ------------------------------------------------------------
-- sp_reporte_obligaciones_pendientes   RF12/CU-12
-- ------------------------------------------------------------
CREATE PROCEDURE sp_reporte_obligaciones_pendientes(
    IN p_criterio  ENUM('proveedor','vencimiento','estado'),
    IN p_desde     DATE,
    IN p_hasta     DATE
)
BEGIN
    SELECT
        razon_social, identificacion,
        numero_factura_proveedor, numero_serie,
        monto_original, saldo_pendiente,
        fecha_vencimiento, fecha_programada,
        estado, dias_para_vencer
    FROM  vw_cuentas_pendientes
    WHERE fecha_vencimiento BETWEEN p_desde AND p_hasta
    ORDER BY
        CASE p_criterio
            WHEN 'proveedor' THEN razon_social
            WHEN 'estado'    THEN estado
            ELSE razon_social
        END ASC,
        -- [2.8] Criterio 'vencimiento' ordena por fecha real, no por texto
        CASE WHEN p_criterio = 'vencimiento' THEN fecha_vencimiento END ASC;
END$$

-- ------------------------------------------------------------
-- sp_estado_cuenta_proveedor   RF09/RF10/CU-09
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
-- sp_alertar_pagos_por_vencer
-- RF10/CU-10 — Horizonte de días configurable (por defecto 7).
-- La vista vw_pagos_por_vencer usa 7 días fijo como valor
-- predeterminado; este SP permite pasar un horizonte distinto.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_alertar_pagos_por_vencer(
    IN p_dias INT
)
BEGIN
    IF p_dias IS NULL OR p_dias <= 0 THEN
        SET p_dias = 7;
    END IF;

    SELECT
        c.id_cxp,
        p.razon_social,
        p.identificacion,
        f.numero_factura_proveedor,
        c.saldo_pendiente,
        c.fecha_vencimiento,
        c.fecha_programada,
        fn_dias_vencimiento(c.fecha_vencimiento) AS dias_para_vencer
    FROM  CuentaPorPagar c
    JOIN  Proveedor        p ON p.id_proveedor    = c.id_proveedor
    JOIN  FacturaProveedor f ON f.id_factura_prov = c.id_factura_prov
    WHERE c.activo = 1
      AND c.estado IN ('pendiente','pagada_parcial')
      AND c.saldo_pendiente > 0
      AND c.fecha_vencimiento BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL p_dias DAY)
    ORDER BY c.fecha_vencimiento ASC;
END$$

-- ------------------------------------------------------------
-- sp_actualizar_cuentas_vencidas
-- RF12 — Marca como 'vencida' las cuentas cuya fecha de vencimiento
-- ya pasó y aún tienen saldo pendiente.
-- Debe ejecutarse periódicamente desde la capa de aplicación
-- (ej. tarea programada diaria).
-- ------------------------------------------------------------
CREATE PROCEDURE sp_actualizar_cuentas_vencidas()
BEGIN
    -- [3.5] Auditoría RNF04: registrar ejecución del proceso batch de vencimientos
    --       Se registra una entrada de auditoría global por ejecución del proceso,
    --       con la cantidad de cuentas afectadas (evita una fila por cada CxP).
    DECLARE v_afectadas INT DEFAULT 0;

    UPDATE CuentaPorPagar
    SET    estado             = 'vencida',
           fecha_modificacion = NOW()
    WHERE  fecha_vencimiento < CURDATE()
      AND  saldo_pendiente   > 0
      AND  estado            IN ('pendiente', 'pagada_parcial')
      AND  activo            = 1;

    SET v_afectadas = ROW_COUNT();

    IF v_afectadas > 0 THEN
        INSERT INTO BitacoraAuditoria (tabla_afectada, operacion, id_registro, usuario, valor_nuevo, fecha_evento)
        VALUES ('CuentaPorPagar', 'BATCH_VENCIMIENTO', 0, 'proceso_automatico',
                JSON_OBJECT('cuentas_marcadas_vencidas', v_afectadas, 'fecha_corte', CURDATE()),
                NOW());
    END IF;
END$$

-- ------------------------------------------------------------
-- sp_reintentar_notificaciones_modb
-- RNF02 — reintento de notificaciones fallidas IF-03 → MOD-B
-- ------------------------------------------------------------
CREATE PROCEDURE sp_reintentar_notificaciones_modb()
BEGIN
    SELECT id_recepcion, id_oc, ref_mod_b_id_producto, cantidad_recibida
    FROM   vw_recepciones_pendientes_notificar;
END$$

-- ------------------------------------------------------------
-- sp_registrar_error_sincronizacion
-- RNF02 — Registro genérico de fallos de comunicación entre módulos.
-- Usable para IF-03 (MOD-B inventario), IF-05/IF-06 (MOD-D impuestos).
-- La capa de aplicación llama este SP cuando detecta un error
-- de comunicación con un módulo externo.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_registrar_error_sincronizacion(
    IN p_modulo_destino  VARCHAR(20),
    IN p_interfaz        VARCHAR(20),
    IN p_id_referencia   INT UNSIGNED,
    IN p_mensaje_error   TEXT
)
BEGIN
    INSERT INTO LogSincronizacion (modulo_destino, interfaz, id_referencia, estado, mensaje_error, fecha_registro)
    VALUES (p_modulo_destino, p_interfaz, p_id_referencia, 'fallido', p_mensaje_error, NOW());
END$$

-- ------------------------------------------------------------
-- sp_consultar_precio_costo_producto
-- RF16/CU-14 — ServicioConsultaCostosA IF-01 para MOD-A
-- [FIX-19] Respuesta controlada si no hay costo registrado:
--          devuelve fila con estado_consulta='SIN_COSTO_REGISTRADO'
--          para que MOD-A no interprete resultado vacío como error.
-- [3.5]   Estado restringido a recibida_parcial/recibida_total:
--         "costo de adquisición" = costo de mercadería efectivamente
--         recibida, no solo pactada. Órdenes en estado emitida se
--         excluyen porque aún no hay entrega confirmada.
-- ------------------------------------------------------------
CREATE PROCEDURE sp_consultar_precio_costo_producto(
    IN p_ref_mod_b_id_producto INT UNSIGNED
)
BEGIN
    DECLARE v_count INT DEFAULT 0;

    SELECT COUNT(*) INTO v_count
    FROM   DetalleOrdenCompra d
    JOIN   OrdenCompra o ON o.id_oc = d.id_oc
    WHERE  d.ref_mod_b_id_producto = p_ref_mod_b_id_producto
      AND  d.activo = 1 AND o.activo = 1
      -- [3.5] Solo OC con mercadería efectivamente recibida
      AND  o.estado IN ('recibida_parcial', 'recibida_total');

    IF v_count = 0 THEN
        SELECT
            p_ref_mod_b_id_producto AS id_producto,
            NULL                    AS descripcion,
            NULL                    AS precio_costo,
            NULL                    AS numero_oc,
            NULL                    AS fecha_oc,
            NULL                    AS proveedor,
            'SIN_COSTO_REGISTRADO'  AS estado_consulta;
    ELSE
        SELECT
            d.ref_mod_b_id_producto   AS id_producto,
            d.descripcion_al_momento  AS descripcion,
            d.precio_unitario_pactado AS precio_costo,
            o.numero_oc,
            o.fecha_emision           AS fecha_oc,
            p.razon_social            AS proveedor,
            'OK'                      AS estado_consulta
        FROM  DetalleOrdenCompra d
        JOIN  OrdenCompra o ON o.id_oc        = d.id_oc
        JOIN  Proveedor   p ON p.id_proveedor = o.id_proveedor
        WHERE d.ref_mod_b_id_producto = p_ref_mod_b_id_producto
          AND d.activo = 1 AND o.activo = 1
          AND o.estado IN ('recibida_parcial', 'recibida_total')
        ORDER BY o.fecha_emision DESC
        LIMIT 1;
    END IF;
END$$

-- ------------------------------------------------------------
-- sp_consultar_ultimo_costo_adquisicion
-- RF16/CU-14 — ServicioConsultaCostosA IF-01 para MOD-A
-- [FIX-19] Igual que sp_consultar_precio_costo_producto:
--          respuesta controlada si no hay datos.
-- [3.5]   Estado restringido a recibida_parcial/recibida_total
--         (misma decisión de diseño que sp_consultar_precio_costo_producto).
-- ------------------------------------------------------------
CREATE PROCEDURE sp_consultar_ultimo_costo_adquisicion(
    IN p_ref_mod_b_id_producto INT UNSIGNED,
    IN p_limite                INT
)
BEGIN
    DECLARE v_count INT DEFAULT 0;

    SELECT COUNT(*) INTO v_count
    FROM   DetalleOrdenCompra d
    JOIN   OrdenCompra o ON o.id_oc = d.id_oc
    WHERE  d.ref_mod_b_id_producto = p_ref_mod_b_id_producto
      AND  d.activo = 1 AND o.activo = 1
      -- [3.5] Solo OC con mercadería efectivamente recibida
      AND  o.estado IN ('recibida_parcial', 'recibida_total');

    IF v_count = 0 THEN
        SELECT
            p_ref_mod_b_id_producto AS id_producto,
            NULL                    AS descripcion,
            NULL                    AS precio_costo,
            NULL                    AS cantidad_solicitada,
            NULL                    AS numero_oc,
            NULL                    AS fecha_oc,
            NULL                    AS proveedor,
            'SIN_COSTO_REGISTRADO'  AS estado_consulta;
    ELSE
        SELECT
            d.ref_mod_b_id_producto   AS id_producto,
            d.descripcion_al_momento  AS descripcion,
            d.precio_unitario_pactado AS precio_costo,
            d.cantidad_solicitada,
            o.numero_oc,
            o.fecha_emision           AS fecha_oc,
            p.razon_social            AS proveedor,
            'OK'                      AS estado_consulta
        FROM  DetalleOrdenCompra d
        JOIN  OrdenCompra o ON o.id_oc        = d.id_oc
        JOIN  Proveedor   p ON p.id_proveedor = o.id_proveedor
        WHERE d.ref_mod_b_id_producto = p_ref_mod_b_id_producto
          AND d.activo = 1 AND o.activo = 1
          AND o.estado IN ('recibida_parcial', 'recibida_total')
        ORDER BY o.fecha_emision DESC
        LIMIT p_limite;
    END IF;
END$$

DELIMITER ;

-- ============================================================
-- 5. PRUEBAS DE INTEGRACIÓN
-- [FIX-20] Llamadas de ejemplo con IDs acordados entre módulos.
--          Productos 1–20 son el rango acordado para pruebas.
--          No usar en producción; sirven para validar interfaces.
-- ============================================================

-- -- IF-01 / CU-14: consulta de costo para MOD-A (producto del rango acordado)
-- CALL sp_consultar_precio_costo_producto(1);
-- CALL sp_consultar_ultimo_costo_adquisicion(1, 5);

-- -- IF-03 / CU-04: marcar recepción como notificada a MOD-B
-- CALL sp_marcar_recepcion_notificada(1, 'usuario_prueba');

-- -- IF-04 / CU-02: crear OC con snapshot del catálogo MOD-B
-- -- JSON esperado por sp_crear_orden_compra:
-- -- [{"id_producto":1,"codigo_producto":"PROD-001","descripcion":"Producto prueba",
-- --   "unidad_medida":"unidad","cantidad":10,"precio_costo":25.00}]

-- -- IF-05 / CU-05: consultar facturas pendientes de retención para enviar a MOD-D
-- SELECT * FROM vw_facturas_pendientes_retencion;

-- -- IF-05 respuesta: registrar retención devuelta por MOD-D
-- -- CALL sp_actualizar_retencion_desde_modd(1, '<xml>...</xml>', '1234567890123456789012345678901234567890123456789');

-- -- Verificar cola de sincronización IF-02 pendiente para MOD-B
-- SELECT * FROM LogSincronizacion WHERE interfaz = 'IF-02' AND estado = 'pendiente';
