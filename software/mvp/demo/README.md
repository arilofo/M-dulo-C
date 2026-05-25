# Modulo C - Cuentas por Pagar

Consideraciones:


java -version mvn -version
Opción recomendada: instalar con winget Abre PowerShell como administrador y ejecuta: winget install -e --id EclipseAdoptium.Temurin.17.JDK Eclipse Temurin es una distribución OpenJDK y tiene instaladores oficiales para Windows; Microsoft también documenta la instalación de Java en Windows mediante winget. Cuando termine, cierra PowerShell y vuelve a abrirlo. Luego prueba: java -version javac -version Debe salir algo parecido a: openjdk version "17..." javac 17... Instalar Maven En PowerShell como administrador ejecuta: winget install -e --id Apache.Maven Luego cierra y vuelve a abrir PowerShell. Prueba: mvn -version Maven es la herramienta que usará tu proyecto para compilar y descargar dependencias como MySQL Connector/J; la documentación oficial indica que Maven se instala agregando su carpeta bin al PATH. Verificar todo en VS Code Abre VS Code, abre tu carpeta del proyecto y entra en: Terminal → New Terminal Ejecuta: java -version javac -version mvn -version Luego, dentro de la carpeta donde está pom.xml, ejecuta: mvn -DskipTests compile Si compila, ejecuta: mvn compile exec:java Y abre: http://localhost:8080/ Si java -version muestra Java 1.8 Eso significa que Windows está usando una versión vieja. Ejecuta: where java Si aparece una ruta antigua antes que Java 17, hay que ajustar el PATH o JAVA_HOME. La ruta típica de Temurin 17 suele ser algo como: C:\Program Files\Eclipse Adoptium\jdk-17...\bin En ese caso: Busca en Windows: Editar las variables de entorno del sistema. Entra a Variables de entorno. En Variables del sistema, crea o edita: JAVA_HOME = C:\Program Files\Eclipse Adoptium\jdk-17... En Path, agrega: %JAVA_HOME%\bin Sube esa entrada por encima de rutas viejas de Java. Cierra y abre de nuevo PowerShell o VS Code.

SI FALLA MAVEN:
Instalar Chocolatey
Abre PowerShell como administrador. Primero ejecuta esto: Set-ExecutionPolicy Bypass -Scope Process -Force Luego instala Chocolatey con el comando oficial de PowerShell: [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) Chocolatey recomienda instalarlo desde una terminal administrativa y luego verificar con choco o choco -?. Cierra PowerShell y ábrelo de nuevo como administrador. Verifica: choco -v
Instalar Maven con Chocolatey
Ahora ejecuta: choco install maven -y Cuando termine, cierra PowerShell y vuelve a abrirlo. Verifica: mvn -version Maven debe mostrar algo como: Apache Maven ... Java version: 17...
Verifica Java 17
Ejecuta: java -version javac -version Si no tienes Java 17 todavía, instala Java con Chocolatey: choco install temurin17 -y Después cierra y abre PowerShell de nuevo, y vuelve a verificar: java -version javac -version mvn -version 



Prototipo MVP local del Modulo C del SIGE: compras, recepcion, facturas de proveedor, cuentas por pagar, pagos y reportes.

## Stack

- Java 17
- Maven para compilar y resolver MySQL Connector/J
- Servidor HTTP embebido `com.sun.net.httpserver.HttpServer`
- JDBC
- MySQL 8.x
- HTML y CSS simples

No usa Spring Boot, React, Node.js, Python, Tomcat ni frameworks web externos.

## Configuracion

Edita `src/main/resources/app.properties`:

```properties
server.host=localhost
server.port=8080

db.url=jdbc:mysql://localhost:3306/modulo_c?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=America/Guayaquil
db.user=root
db.password=
```

Antes de probar, crea la base `modulo_c` y ejecuta el script del Modulo C desde `DataBase/ScriptsModuloC (1).txt`.

Para probar integraciones reales, tambien deben estar cargados los esquemas externos esperados por el prototipo:

- `modulo_c`: tablas, vistas y procedimientos del script principal del Modulo C.
- `modulo_b`: `productos`, `bodegas`, `movimientos_inventario`, `kardex`.
- `modulo_d`: `retenciones_renta_config`, `retenciones_iva_config`, `tarifas_iva`, `comprobantes_retencion`, `log_xml_comprobantes`.

El archivo de referencia es `DataBase/ScriptsMODS_Externos.sql`. Si alguno de esos esquemas o tablas no existe, la pantalla mostrara un error claro y no completara la integracion.

## Ejecutar

```bash
mvn -DskipTests compile
mvn compile exec:java
```

Luego abre:

```txt
http://localhost:8080
```

## Probar conexion

Con el servidor iniciado, abre:

```txt
http://localhost:8080/db-test
```

La pagina intentara abrir una conexion JDBC y ejecutar `SELECT DATABASE()`.

## Rutas principales

- `/proveedores`
- `/ordenes`
- `/ordenes/pendientes`
- `/recepciones`
- `/recepciones/pendientes-notificar`
- `/facturas`
- `/facturas/pendientes-retencion`
- `/cuentas`
- `/cuentas/pendientes`
- `/cuentas/estado-proveedor`
- `/pagos`
- `/reportes`
- `/reportes/pagos-vencer`
- `/reportes/obligaciones`
- `/reportes/ordenes-pendientes`
- `/reportes/conciliacion`
- `/integraciones`
- `/integraciones/modulo-a-costos`
- `/demo`
- `/rol`

## Roles de demo

El prototipo incluye selector de rol visible en la interfaz. El rol se guarda en una cookie local y se valida antes de acciones criticas:

- Administrador: acceso completo y autorizacion de facturas excepcionales.
- Gerente / Jefe de Compras: proveedores, ordenes, recepciones, facturas y ordenes pendientes.
- Tesorero: cuentas por pagar, programacion de pagos, registro de pagos y reportes financieros.

## Flujo de demo recomendado

1. Abrir `/demo`.
2. Seleccionar rol en `/rol`.
3. Registrar o seleccionar proveedor en `/proveedores`.
4. Crear orden de compra en `/ordenes/nueva` con productos reales de `modulo_b.productos`.
5. Registrar recepcion en `/recepciones/nueva`.
6. Confirmar actualizacion real de inventario en `/recepciones/pendientes-notificar`.
7. Ingresar factura proveedor en `/facturas/nueva`.
8. Seleccionar tarifa IVA real desde `modulo_d.tarifas_iva`.
9. Registrar retencion real en Modulo D desde `/facturas/pendientes-retencion`.
10. Ver cuenta por pagar generada en `/cuentas`.
11. Programar pago en `/cuentas`.
12. Registrar pago en `/pagos/nuevo`.
13. Revisar pagos proximos a vencer con estado y EXPLAIN en `/reportes/pagos-vencer`.
14. Revisar obligaciones pendientes y conciliacion en `/reportes`.
15. Consultar costos expuestos para Modulo A mediante IF-01 en `/integraciones/modulo-a-costos`.

## Probar proveedores

Con MySQL configurado y el servidor iniciado:

1. Abre `http://localhost:8080/proveedores`.
2. Usa `Nuevo proveedor` para abrir el formulario.
3. Para persona natural, ingresa al menos:
   - tipo `persona_natural`;
   - identificacion / RUC;
   - razon social;
   - cedula.
4. Para persona juridica, ingresa al menos:
   - tipo `persona_juridica`;
   - identificacion / RUC;
   - razon social;
   - razon social comercial.
5. Guarda y verifica que aparezca en el listado.
6. Usa `Editar` para actualizar datos generales.
7. Usa `Desactivar` para aplicar borrado logico mediante `sp_eliminar_proveedor_logico`.

La gestion usa estos procedimientos almacenados:

- `sp_registrar_proveedor`
- `sp_actualizar_proveedor`
- `sp_eliminar_proveedor_logico`

## Procedimientos usados por el MVP

- `sp_registrar_proveedor`
- `sp_actualizar_proveedor`
- `sp_eliminar_proveedor_logico`
- `sp_crear_orden_compra`
- `sp_reporte_ordenes_pendientes_recepcion`
- `sp_registrar_recepcion`
- `sp_marcar_recepcion_notificada`
- `sp_ingresar_factura_proveedor`
- `sp_actualizar_retencion_desde_modd`
- `sp_programar_pago`
- `sp_registrar_pago`
- `sp_estado_cuenta_proveedor`
- `sp_alertar_pagos_por_vencer`
- `sp_reporte_obligaciones_pendientes`
- `sp_conciliar_saldos_proveedor`
- `sp_consultar_precio_costo_producto`
- `sp_consultar_ultimo_costo_adquisicion`
- `sp_registrar_error_sincronizacion`

## Integraciones reales

- IF-01 Modulo A: `/integraciones/modulo-a-costos` consulta costos mediante `sp_consultar_precio_costo_producto` y `sp_consultar_ultimo_costo_adquisicion`.
- Ordenes de compra leen productos activos desde `modulo_b.productos`.
- IF-02 Modulo B: el script externo revisado no define una tabla, vista o procedimiento real de solicitudes de compra. Por eso `/ordenes/nueva` mantiene `id_solicitud` como referencia logica manual, sin inventar tablas ni datos.
- Recepciones llaman `sp_registrar_recepcion`, actualizan inventario real en `modulo_b.productos`, registran `modulo_b.movimientos_inventario`, registran `modulo_b.kardex` y solo despues llaman `sp_marcar_recepcion_notificada`.
- En recepciones parciales, `/recepciones/nueva?ordenId=...` muestra solicitado, recibido anteriormente y restante por cada detalle antes de llamar al procedimiento.
- El boton `Recibir totalmente` llena automaticamente las cantidades restantes, no las cantidades solicitadas originales.
- Facturas cargan tarifas IVA reales desde `modulo_d.tarifas_iva`. El valor IVA se calcula automaticamente desde la tarifa real seleccionada del Modulo D; el usuario no debe ingresar manualmente el IVA.
- La base imponible de factura se sugiere desde el subtotal de la recepcion seleccionada o desde el total de la orden si no hay recepcion cargada. El backend valida que no supere la base pendiente facturable antes de llamar `sp_ingresar_factura_proveedor`.
- La firma actual de `sp_ingresar_factura_proveedor` no recibe fecha de emision explicita; el procedimiento registra la fecha automaticamente.
- Retenciones leen configuraciones reales de `modulo_d.retenciones_renta_config` y `modulo_d.retenciones_iva_config`, insertan en `modulo_d.comprobantes_retencion` y `modulo_d.log_xml_comprobantes`, y luego llaman `sp_actualizar_retencion_desde_modd`.
- Pagos por vencer usan `sp_alertar_pagos_por_vencer`, complementan el estado desde `CuentaPorPagar` cuando el SP no lo devuelve y permiten mostrar `EXPLAIN` de la consulta optimizada.
- Si falla una integracion real con Modulo B o Modulo D, el sistema intenta registrar el fallo en `LogSincronizacion` mediante `sp_registrar_error_sincronizacion` y mantiene visible el error principal para el usuario.
