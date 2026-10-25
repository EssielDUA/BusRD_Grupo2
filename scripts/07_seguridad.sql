/* =========================================================
   BusRD - E4. Seguridad: roles, vistas, permisos y pruebas
   Requiere E1, E2 (procedimientos) y E3 ejecutados.
   Usuarios de prueba SIN login; se prueban con EXECUTE AS USER / REVERT.
   ========================================================= */
USE BusRD;
GO

/* =========================================================
   PASO 1. VISTAS (el acceso de taquilla y reportes pasa por aqui, no por las tablas)
   ========================================================= */
CREATE OR ALTER VIEW dbo.vw_AsientosDisponibles
AS
SELECT v.ViajeID, v.FechaSalida, r.Origen, r.Destino, s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = v.ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo');
GO

CREATE OR ALTER VIEW dbo.vw_VentasMensuales
AS
SELECT YEAR(b.FechaVenta) AS Anio, MONTH(b.FechaVenta) AS Mes,
       r.Origen, r.Destino,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.Estado = 'Activo'
GROUP BY YEAR(b.FechaVenta), MONTH(b.FechaVenta), r.Origen, r.Destino;
GO

/* =========================================================
   PASO 2. ROLES
   ========================================================= */
IF DATABASE_PRINCIPAL_ID('rol_taquilla') IS NULL CREATE ROLE rol_taquilla;
IF DATABASE_PRINCIPAL_ID('rol_reportes') IS NULL CREATE ROLE rol_reportes;
IF DATABASE_PRINCIPAL_ID('rol_admin')    IS NULL CREATE ROLE rol_admin;
GO

/* =========================================================
   PASO 3. USUARIOS DE PRUEBA (sin login) Y MEMBRESIA
   ========================================================= */
IF DATABASE_PRINCIPAL_ID('usr_taquilla') IS NULL CREATE USER usr_taquilla WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID('usr_reportes') IS NULL CREATE USER usr_reportes WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID('usr_admin')    IS NULL CREATE USER usr_admin    WITHOUT LOGIN;
GO
IF ISNULL(IS_ROLEMEMBER('rol_taquilla', 'usr_taquilla'), 0) = 0 ALTER ROLE rol_taquilla ADD MEMBER usr_taquilla;
IF ISNULL(IS_ROLEMEMBER('rol_reportes', 'usr_reportes'), 0) = 0 ALTER ROLE rol_reportes ADD MEMBER usr_reportes;
IF ISNULL(IS_ROLEMEMBER('rol_admin',    'usr_admin'),    0) = 0 ALTER ROLE rol_admin    ADD MEMBER usr_admin;
GO

/* =========================================================
   PASO 4. PERMISOS (minimo privilegio)
   ========================================================= */
-- rol_taquilla: solo ejecutar los 2 procedimientos y leer la vista. Sin acceso a tablas.
GRANT EXECUTE ON dbo.sp_VenderBoleto TO rol_taquilla;
GRANT EXECUTE ON dbo.sp_AnularBoleto TO rol_taquilla;
GRANT SELECT  ON dbo.vw_AsientosDisponibles TO rol_taquilla;

-- rol_reportes: solo la vista de ventas; ademas, DENY explicito a Email y Telefono
GRANT SELECT ON dbo.vw_VentasMensuales TO rol_reportes;
DENY  SELECT ON dbo.Clientes(Email, Telefono) TO rol_reportes;

-- rol_admin: control total de ESTA base de datos (no del servidor)
GRANT CONTROL ON DATABASE::BusRD TO rol_admin;
GO

/* =========================================================
   PASO 5. MATRIZ DE ROLES Y PERMISOS (evidencia)
   ========================================================= */
SELECT r.name AS Rol, m.name AS Usuario
FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
WHERE r.name LIKE 'rol[_]%'
ORDER BY r.name;

SELECT pr.name AS Rol, pe.state_desc AS Estado, pe.permission_name AS Permiso,
       pe.class_desc AS Clase, OBJECT_NAME(pe.major_id) AS Objeto, col.name AS Columna
FROM sys.database_permissions pe
JOIN sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
LEFT JOIN sys.columns col ON col.object_id = pe.major_id
                         AND col.column_id = pe.minor_id AND pe.minor_id > 0
WHERE pr.name LIKE 'rol[_]%'
ORDER BY pr.name, pe.permission_name;
GO

/* =========================================================
   PASO 6. PRUEBAS: accesos permitidos y denegados por rol
   Se ejecuta TODO este bloque junto (una sola tabla de resultados).
   Los intentos "denegados" usan WHERE 1 = 0 o parametros invalidos para no
   danar datos aunque, por error, se permitieran.
   La venta de prueba de taquilla se anula al final (queda Anulado con reverso).
   ========================================================= */
SET NOCOUNT ON;
DECLARE @R TABLE (Rol VARCHAR(10), Prueba VARCHAR(70), Esperado VARCHAR(10),
                  Obtenido VARCHAR(20), Detalle NVARCHAR(300));
DECLARE @V INT, @A INT, @n INT, @id INT;

-- Viaje Programado y asiento libre (como dbo)
SELECT TOP (1) @V = ViajeID FROM dbo.Viajes
WHERE Estado = 'Programado' ORDER BY FechaSalida DESC, ViajeID;

SELECT TOP (1) @A = s.NumeroAsiento
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @V
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = @V AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento DESC;

/* ================= rol_taquilla ================= */
EXECUTE AS USER = 'usr_taquilla';
BEGIN TRY
    SELECT @n = COUNT(*) FROM dbo.vw_AsientosDisponibles WHERE ViajeID = @V;
    INSERT @R VALUES ('taquilla', 'SELECT en vw_AsientosDisponibles', 'PERMITIDO', 'PERMITIDO',
                      'Asientos libres del viaje ' + CAST(@V AS VARCHAR(10)) + ': ' + CAST(@n AS VARCHAR(10)));
END TRY
BEGIN CATCH
    INSERT @R VALUES ('taquilla', 'SELECT en vw_AsientosDisponibles', 'PERMITIDO',
                      'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)), LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_taquilla';
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, @A, 1, 'Taquilla', 'Efectivo', @id OUTPUT;
    INSERT @R VALUES ('taquilla', 'EXEC sp_VenderBoleto', 'PERMITIDO', 'PERMITIDO',
                      'BoletoID generado = ' + CAST(@id AS VARCHAR(10)));
END TRY
BEGIN CATCH
    INSERT @R VALUES ('taquilla', 'EXEC sp_VenderBoleto', 'PERMITIDO',
                      'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)), LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_taquilla';
BEGIN TRY
    EXEC dbo.sp_AnularBoleto @id;
    INSERT @R VALUES ('taquilla', 'EXEC sp_AnularBoleto', 'PERMITIDO', 'PERMITIDO', 'Boleto anulado con reverso');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('taquilla', 'EXEC sp_AnularBoleto', 'PERMITIDO',
                      'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)), LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_taquilla';
BEGIN TRY
    EXEC('SELECT COUNT(*) FROM dbo.Boletos');
    INSERT @R VALUES ('taquilla', 'SELECT directo en dbo.Boletos', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('taquilla', 'SELECT directo en dbo.Boletos', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_taquilla';
BEGIN TRY
    EXEC('SELECT Cedula, Email FROM dbo.Clientes');
    INSERT @R VALUES ('taquilla', 'SELECT directo en dbo.Clientes', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('taquilla', 'SELECT directo en dbo.Clientes', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_taquilla';
BEGIN TRY
    EXEC('DELETE FROM dbo.Boletos WHERE 1 = 0');
    INSERT @R VALUES ('taquilla', 'DELETE directo en dbo.Boletos', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('taquilla', 'DELETE directo en dbo.Boletos', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

/* ================= rol_reportes ================= */
EXECUTE AS USER = 'usr_reportes';
BEGIN TRY
    SELECT @n = COUNT(*) FROM dbo.vw_VentasMensuales;
    INSERT @R VALUES ('reportes', 'SELECT en vw_VentasMensuales', 'PERMITIDO', 'PERMITIDO',
                      'Filas de la vista: ' + CAST(@n AS VARCHAR(10)));
END TRY
BEGIN CATCH
    INSERT @R VALUES ('reportes', 'SELECT en vw_VentasMensuales', 'PERMITIDO',
                      'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)), LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_reportes';
BEGIN TRY
    SELECT @n = COUNT(*) FROM dbo.vw_VentasMensuales WHERE Anio = 2025;
    INSERT @R VALUES ('reportes', 'SELECT filtrado (Anio = 2025) en la vista', 'PERMITIDO', 'PERMITIDO',
                      'Filas 2025: ' + CAST(@n AS VARCHAR(10)));
END TRY
BEGIN CATCH
    INSERT @R VALUES ('reportes', 'SELECT filtrado (Anio = 2025) en la vista', 'PERMITIDO',
                      'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)), LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_reportes';
BEGIN TRY
    EXEC('SELECT Email, Telefono FROM dbo.Clientes');
    INSERT @R VALUES ('reportes', 'SELECT Email, Telefono en dbo.Clientes', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('reportes', 'SELECT Email, Telefono en dbo.Clientes', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_reportes';
BEGIN TRY
    EXEC('SELECT COUNT(*) FROM dbo.Boletos');
    INSERT @R VALUES ('reportes', 'SELECT directo en dbo.Boletos', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('reportes', 'SELECT directo en dbo.Boletos', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_reportes';
BEGIN TRY
    EXEC('DECLARE @x INT; EXEC dbo.sp_VenderBoleto 0, 1, 1, ''Web'', ''Tarjeta'', @x OUTPUT;');
    INSERT @R VALUES ('reportes', 'EXEC sp_VenderBoleto', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('reportes', 'EXEC sp_VenderBoleto', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

/* ================= rol_admin (administra la BASE, no el servidor) ================= */
EXECUTE AS USER = 'usr_admin';
BEGIN TRY
    SELECT @n = COUNT(*) FROM dbo.Boletos;
    INSERT @R VALUES ('admin', 'SELECT en dbo.Boletos', 'PERMITIDO', 'PERMITIDO',
                      'Boletos: ' + CAST(@n AS VARCHAR(10)));
END TRY
BEGIN CATCH
    INSERT @R VALUES ('admin', 'SELECT en dbo.Boletos', 'PERMITIDO',
                      'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)), LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_admin';
BEGIN TRY
    EXEC('CREATE TABLE dbo.zz_prueba_admin (id INT); DROP TABLE dbo.zz_prueba_admin;');
    INSERT @R VALUES ('admin', 'CREATE TABLE / DROP TABLE en la base', 'PERMITIDO', 'PERMITIDO', 'DDL permitido');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('admin', 'CREATE TABLE / DROP TABLE en la base', 'PERMITIDO',
                      'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)), LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_admin';
BEGIN TRY
    EXEC('CREATE LOGIN zz_login_prueba WITH PASSWORD = ''Pr#eba2026!Segura''');
    INSERT @R VALUES ('admin', 'CREATE LOGIN (nivel servidor)', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('admin', 'CREATE LOGIN (nivel servidor)', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

EXECUTE AS USER = 'usr_admin';
BEGIN TRY
    EXEC('CREATE DATABASE zz_db_prueba');
    INSERT @R VALUES ('admin', 'CREATE DATABASE (nivel servidor)', 'DENEGADO', 'PERMITIDO', 'DEBIO DENEGARSE');
END TRY
BEGIN CATCH
    INSERT @R VALUES ('admin', 'CREATE DATABASE (nivel servidor)', 'DENEGADO',
        CASE WHEN ERROR_NUMBER() IN (229,230,262,297,300,916,15247) THEN 'DENEGADO'
             ELSE 'ERROR ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) END, LEFT(ERROR_MESSAGE(), 300));
END CATCH
REVERT;

/* Limpieza por si alguna prueba "denegada" hubiera creado algo */
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'zz_login_prueba') DROP LOGIN zz_login_prueba;
IF DB_ID('zz_db_prueba') IS NOT NULL DROP DATABASE zz_db_prueba;

SELECT Rol, Prueba, Esperado, Obtenido,
       CASE WHEN Esperado = Obtenido THEN 'OK' ELSE 'REVISAR' END AS Resultado,
       Detalle
FROM @R;
GO
