/* =========================================================
   BusRD - E5. Respaldo y recuperacion (STOPAT)
   Ejecutar PASO por PASO, en orden, en la misma pestana de SSMS.
   Antes de empezar:
   - Crear la carpeta C:\Backups\BusRD\ y darle permiso de escritura a la cuenta del
     servicio de SQL Server (en Express: NT Service\MSSQL$SQLEXPRESS). Si da error 3201
     (acceso denegado), es casi siempre este permiso.
   - Hacer E3 antes: el DELETE de este script borra los boletos del viaje asignado.
   ========================================================= */

/* =========================================================
   PASO 1. Modelo de recuperacion FULL + tablas de control
   Por que FULL: en SIMPLE el log se trunca solo en cada checkpoint, no se pueden hacer
   respaldos de log ni restaurar a un punto en el tiempo (STOPAT). FULL conserva el log
   hasta que se respalda, permitiendo recuperar justo antes de un error humano.
   Costo: hay que programar respaldos de log, o el archivo de log crece sin parar.
   ========================================================= */
USE master;
GO
ALTER DATABASE BusRD SET RECOVERY FULL;
GO
USE BusRD;
GO
IF OBJECT_ID('dbo.E5_Control') IS NULL
    CREATE TABLE dbo.E5_Control(Clave VARCHAR(30) NOT NULL PRIMARY KEY, Valor VARCHAR(100) NOT NULL);
IF OBJECT_ID('dbo.E5_Ventas_Prueba') IS NULL
    CREATE TABLE dbo.E5_Ventas_Prueba(
        BoletoID INT NOT NULL PRIMARY KEY, Etapa VARCHAR(40) NOT NULL,
        FechaRegistro DATETIME2(0) NOT NULL DEFAULT SYSDATETIME());
GO
DELETE FROM dbo.E5_Control;
DELETE FROM dbo.E5_Ventas_Prueba;

DECLARE @ViajeAsignado INT = 16000;       -- <<< viaje asignado por el docente
DECLARE @ViajeVenta    INT = (SELECT TOP (1) ViajeID FROM dbo.Viajes
                              WHERE Estado = 'Programado' ORDER BY FechaSalida DESC, ViajeID);
INSERT dbo.E5_Control VALUES ('ViajeAsignado', CAST(@ViajeAsignado AS VARCHAR(10)));
INSERT dbo.E5_Control VALUES ('ViajeVenta',    CAST(@ViajeVenta    AS VARCHAR(10)));

SELECT name AS BaseDeDatos, recovery_model_desc AS ModeloRecuperacion
FROM sys.databases WHERE name = 'BusRD';
SELECT * FROM dbo.E5_Control;
GO

/* =========================================================
   PASO 2. Backup FULL
   ========================================================= */
BACKUP DATABASE BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_01_full.bak'
WITH INIT, CHECKSUM, STATS = 10, NAME = N'BusRD - FULL';
GO

/* =========================================================
   PASO 3. Vender 5 boletos (despues del FULL)
   ========================================================= */
USE BusRD;
GO
DECLARE @V INT = (SELECT CAST(Valor AS INT) FROM dbo.E5_Control WHERE Clave = 'ViajeVenta');
DECLARE @i INT = 1, @A INT, @id INT;
WHILE @i <= 5
BEGIN
    SET @A = NULL;
    SELECT TOP (1) @A = s.NumeroAsiento
    FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.ViajeID = @V
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                      WHERE b.ViajeID = @V AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo')
    ORDER BY s.NumeroAsiento;

    EXEC dbo.sp_VenderBoleto @V, @A, @i, 'Taquilla', 'Efectivo', @id OUTPUT;
    INSERT dbo.E5_Ventas_Prueba(BoletoID, Etapa) VALUES (@id, '1 - despues del FULL');
    SET @i += 1;
END
SELECT e.BoletoID, e.Etapa, b.ViajeID, b.NumeroAsiento, b.Estado
FROM dbo.E5_Ventas_Prueba e JOIN dbo.Boletos b ON b.BoletoID = e.BoletoID
ORDER BY e.BoletoID;
GO

/* =========================================================
   PASO 4. Backup DIFERENCIAL
   ========================================================= */
BACKUP DATABASE BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_02_diff.bak'
WITH DIFFERENTIAL, INIT, CHECKSUM, STATS = 10, NAME = N'BusRD - DIFERENCIAL';
GO

/* =========================================================
   PASO 5. Vender 3 boletos (despues del DIFERENCIAL)
   ========================================================= */
USE BusRD;
GO
DECLARE @V INT = (SELECT CAST(Valor AS INT) FROM dbo.E5_Control WHERE Clave = 'ViajeVenta');
DECLARE @i INT = 6, @A INT, @id INT;
WHILE @i <= 8
BEGIN
    SET @A = NULL;
    SELECT TOP (1) @A = s.NumeroAsiento
    FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.ViajeID = @V
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                      WHERE b.ViajeID = @V AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo')
    ORDER BY s.NumeroAsiento;

    EXEC dbo.sp_VenderBoleto @V, @A, @i, 'Web', 'Tarjeta', @id OUTPUT;
    INSERT dbo.E5_Ventas_Prueba(BoletoID, Etapa) VALUES (@id, '2 - despues del DIFERENCIAL');
    SET @i += 1;
END
SELECT e.BoletoID, e.Etapa, b.ViajeID, b.NumeroAsiento, b.Estado
FROM dbo.E5_Ventas_Prueba e JOIN dbo.Boletos b ON b.BoletoID = e.BoletoID
ORDER BY e.BoletoID;
GO

/* =========================================================
   PASO 6. Backup de LOG
   ========================================================= */
BACKUP LOG BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_03_log.trn'
WITH INIT, CHECKSUM, STATS = 10, NAME = N'BusRD - LOG 1';
GO

/* =========================================================
   PASO 7. Anotar la HORA EXACTA (justo antes del "error")
   Guarda cuantos boletos/pagos tenia el viaje asignado y la hora del STOPAT.
   Captura el resultado: esa es la hora que se usa al restaurar.
   ========================================================= */
USE BusRD;
GO
DECLARE @VA INT = (SELECT CAST(Valor AS INT) FROM dbo.E5_Control WHERE Clave = 'ViajeAsignado');
WAITFOR DELAY '00:00:03';
INSERT dbo.E5_Control VALUES ('BoletosViajeAsignado',
    CAST((SELECT COUNT(*) FROM dbo.Boletos WHERE ViajeID = @VA) AS VARCHAR(20)));
INSERT dbo.E5_Control VALUES ('PagosViajeAsignado',
    CAST((SELECT COUNT(*) FROM dbo.Pagos p JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID
          WHERE b.ViajeID = @VA) AS VARCHAR(20)));
WAITFOR DELAY '00:00:03';

DECLARE @StopAt DATETIME = GETDATE();
INSERT dbo.E5_Control VALUES ('StopAt', CONVERT(VARCHAR(23), @StopAt, 121));

SELECT CONVERT(VARCHAR(23), @StopAt, 121) AS HoraExacta_STOPAT,
       @VA AS ViajeAsignado,
       (SELECT Valor FROM dbo.E5_Control WHERE Clave = 'BoletosViajeAsignado') AS BoletosAntesDelError,
       (SELECT Valor FROM dbo.E5_Control WHERE Clave = 'PagosViajeAsignado')   AS PagosAntesDelError;
GO

/* =========================================================
   PASO 8. SIMULAR EL ERROR: borrar todos los boletos del viaje asignado
   (se espera unos segundos tras el paso 7 para que el DELETE ocurra DESPUES del STOPAT)
   Nota: la FK Pagos -> Boletos obliga a borrar primero los pagos; ambos se recuperan.
   ========================================================= */
USE BusRD;
GO
WAITFOR DELAY '00:00:03';
DECLARE @VA INT = (SELECT CAST(Valor AS INT) FROM dbo.E5_Control WHERE Clave = 'ViajeAsignado');
BEGIN TRAN;
    DELETE p FROM dbo.Pagos p JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID WHERE b.ViajeID = @VA;
    DELETE FROM dbo.Boletos WHERE ViajeID = @VA;
COMMIT;
SELECT @VA AS ViajeAsignado, COUNT(*) AS BoletosRestantes_DespuesDelDELETE
FROM dbo.Boletos WHERE ViajeID = @VA;     -- debe dar 0
GO

/* =========================================================
   PASO 9. Backup de LOG de COLA (contiene el DELETE)
   ========================================================= */
BACKUP LOG BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_04_log_cola.trn'
WITH INIT, CHECKSUM, STATS = 10, NAME = N'BusRD - LOG de cola';
GO

/* Historial de respaldos (evidencia) */
SELECT CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFERENCIAL' WHEN 'L' THEN 'LOG' END AS Tipo,
       bs.backup_start_date AS Inicio, bs.backup_finish_date AS Fin,
       CAST(bs.backup_size / 1048576.0 AS DECIMAL(10,2)) AS MB,
       bmf.physical_device_name AS Archivo
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'BusRD'
ORDER BY bs.backup_start_date;
GO

/* =========================================================
   PASO 10. RESTAURAR en BusRD_Recuperada hasta un momento ANTES del DELETE
   ========================================================= */
USE master;
GO
-- 10.1 Nombres logicos de los archivos (deben ser BusRD y BusRD_log)
RESTORE FILELISTONLY FROM DISK = N'C:\Backups\BusRD\BusRD_01_full.bak';
GO

-- 10.2 Restauracion en cadena: FULL -> DIFERENCIAL -> LOG -> LOG de cola con STOPAT
DECLARE @dataPath NVARCHAR(260) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(260));
DECLARE @logPath  NVARCHAR(260) = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS NVARCHAR(260));
DECLARE @mdf NVARCHAR(300) = @dataPath + N'BusRD_Recuperada.mdf';
DECLARE @ldf NVARCHAR(300) = @logPath  + N'BusRD_Recuperada_log.ldf';
DECLARE @StopAt DATETIME = (SELECT CONVERT(DATETIME, Valor, 121)
                            FROM BusRD.dbo.E5_Control WHERE Clave = 'StopAt');
PRINT 'STOPAT = ' + CONVERT(VARCHAR(23), @StopAt, 121);

IF DB_ID('BusRD_Recuperada') IS NOT NULL
BEGIN
    ALTER DATABASE BusRD_Recuperada SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BusRD_Recuperada;
END

RESTORE DATABASE BusRD_Recuperada
FROM DISK = N'C:\Backups\BusRD\BusRD_01_full.bak'
WITH MOVE N'BusRD' TO @mdf, MOVE N'BusRD_log' TO @ldf, NORECOVERY, STATS = 20;

RESTORE DATABASE BusRD_Recuperada
FROM DISK = N'C:\Backups\BusRD\BusRD_02_diff.bak'
WITH NORECOVERY, STATS = 20;

RESTORE LOG BusRD_Recuperada
FROM DISK = N'C:\Backups\BusRD\BusRD_03_log.trn'
WITH NORECOVERY, STATS = 20;

RESTORE LOG BusRD_Recuperada
FROM DISK = N'C:\Backups\BusRD\BusRD_04_log_cola.trn'
WITH STOPAT = @StopAt, RECOVERY, STATS = 20;
GO

/* =========================================================
   PASO 11. VERIFICACION
   ========================================================= */
USE master;
GO
DECLARE @VA INT = (SELECT CAST(Valor AS INT) FROM BusRD.dbo.E5_Control WHERE Clave = 'ViajeAsignado');
;WITH x AS (
    SELECT '1. Boletos de prueba (los 8 vendidos) en BusRD_Recuperada' AS Control,
           8 AS Esperado, COUNT(*) AS Obtenido
    FROM BusRD_Recuperada.dbo.E5_Ventas_Prueba e
    JOIN BusRD_Recuperada.dbo.Boletos b ON b.BoletoID = e.BoletoID
    UNION ALL
    SELECT '2. Boletos del viaje asignado en BusRD (despues del DELETE)', 0, COUNT(*)
    FROM BusRD.dbo.Boletos WHERE ViajeID = @VA
    UNION ALL
    SELECT '3. Boletos del viaje asignado en BusRD_Recuperada',
           (SELECT CAST(Valor AS INT) FROM BusRD_Recuperada.dbo.E5_Control WHERE Clave = 'BoletosViajeAsignado'),
           COUNT(*)
    FROM BusRD_Recuperada.dbo.Boletos WHERE ViajeID = @VA
    UNION ALL
    SELECT '4. Pagos de esos boletos en BusRD_Recuperada',
           (SELECT CAST(Valor AS INT) FROM BusRD_Recuperada.dbo.E5_Control WHERE Clave = 'PagosViajeAsignado'),
           COUNT(*)
    FROM BusRD_Recuperada.dbo.Pagos p
    JOIN BusRD_Recuperada.dbo.Boletos b ON b.BoletoID = p.BoletoID
    WHERE b.ViajeID = @VA
)
SELECT Control, Esperado, Obtenido,
       CASE WHEN Esperado = Obtenido THEN 'OK' ELSE 'REVISAR' END AS Resultado
FROM x;

SELECT e.BoletoID, e.Etapa, b.ViajeID, b.NumeroAsiento, b.Estado
FROM BusRD_Recuperada.dbo.E5_Ventas_Prueba e
JOIN BusRD_Recuperada.dbo.Boletos b ON b.BoletoID = e.BoletoID
ORDER BY e.BoletoID;
GO

/* =========================================================
   POLITICA DE RESPALDOS PROPUESTA (para el informe)
   Tipo        | Frecuencia                        | Retencion
   FULL        | Semanal (domingo 02:00)           | 4 semanas en disco + 1 mensual por 12 meses (copia externa)
   DIFERENCIAL | Diario (02:00, lunes a sabado)    | 2 semanas
   LOG         | Cada 15 minutos                   | 14 dias
   Verificacion: RESTORE VERIFYONLY tras cada full, DBCC CHECKDB semanal y
   prueba de restauracion mensual en BusRD_Recuperada.
   En SQL Server Express no existe el Agente: se automatiza con el Programador de
   tareas de Windows + sqlcmd (en Standard/Enterprise seria un job del Agente).
   RPO objetivo: 15 min (limitado por el log).
   ========================================================= */
