/* =========================================================
   BusRD - E3. Optimizacion de las 3 consultas lentas
   Grupo 2 | Cedula para C2 = 40200002000
   Viaje para C1 = 16000 (PROVISIONAL: con Ctrl+H reemplaza 16000 por el viaje asignado)

   COMO USARLO PARA LAS CAPTURAS
   - Misma pestana de SSMS para todo el script (usa tablas temporales).
   - Ctrl+M activa "Incluir plan de ejecucion real". Desactivalo en los bloques 4 y 7.
   - Ejecuta cada bloque seleccionandolo (F5 con el texto seleccionado), en orden.
   - Cada consulta: ejecutala 2 veces y captura la segunda (cache caliente).
   Requiere E1 y E2 ya ejecutados.
   ========================================================= */
USE BusRD;
GO

/* =========================================================
   BLOQUE 0. Indices existentes (estado inicial)
   ========================================================= */
SELECT OBJECT_NAME(i.object_id) AS Tabla, i.name AS Indice, i.type_desc AS Tipo,
       i.is_unique AS Unico, i.has_filter AS Filtrado, i.is_disabled AS Deshabilitado
FROM sys.indexes i
WHERE i.object_id IN (OBJECT_ID('dbo.Boletos'), OBJECT_ID('dbo.Pagos'), OBJECT_ID('dbo.Clientes'),
                      OBJECT_ID('dbo.Viajes'),  OBJECT_ID('dbo.Asientos'), OBJECT_ID('dbo.Rutas'))
  AND i.type > 0
ORDER BY Tabla, Indice;
GO

/* =========================================================
   BLOQUE 1. Preparar la LINEA BASE
   La base entregada NO tenia indices secundarios. El indice unico filtrado
   UX_Boletos_Viaje_Asiento_Activo lo creamos en E1 por integridad y, de paso,
   cubre la consulta C1. Para medir la linea base real lo deshabilitamos un momento
   (se vuelve a habilitar en el BLOQUE 3).
   ========================================================= */
ALTER INDEX UX_Boletos_Viaje_Asiento_Activo ON dbo.Boletos DISABLE;
GO

/* =========================================================
   BLOQUE 2. LINEA BASE - consultas ORIGINALES (script 03)
   Ctrl+M activado. Captura: plan real + pestana Messages (lecturas logicas, CPU).
   ========================================================= */
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

/* ---- C1 original: asientos disponibles de un viaje ---- */
DECLARE @ViajeID INT = 16000;          -- <<< viaje asignado
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND s.NumeroAsiento NOT IN (SELECT b.NumeroAsiento
                              FROM dbo.Boletos b
                              WHERE b.ViajeID = @ViajeID
                                AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;
GO

/* ---- C2 original: historial de un cliente por cedula ---- */
DECLARE @Cedula CHAR(11) = '40200002000';      -- cliente N° 2000 (grupo 2)
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula
ORDER BY v.FechaSalida DESC;
GO

/* ---- C3 original: ingresos mensuales por ruta, 2025 ---- */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE YEAR(b.FechaVenta) = 2025
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;
GO

/* =========================================================
   BLOQUE 3. Volver a habilitar el indice unico de E1 (IMPORTANTE)
   ========================================================= */
ALTER INDEX UX_Boletos_Viaje_Asiento_Activo ON dbo.Boletos REBUILD;
GO
SELECT name, is_disabled AS Deshabilitado, has_filter AS Filtrado
FROM sys.indexes WHERE name = 'UX_Boletos_Viaje_Asiento_Activo';   -- debe dar 0
GO

/* =========================================================
   BLOQUE 4. Costo de ESCRITURA ANTES de crear los indices nuevos
   Procedimiento auxiliar: ejecuta 1000 ventas con sp_VenderBoleto dentro de una
   transaccion y la REVIERTE (no deja datos; solo consume numeros de identidad).
   Desactiva Ctrl+M (plan real) para este bloque. Ejecutalo 3 veces y anota el menor tiempo.
   ========================================================= */
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
CREATE OR ALTER PROCEDURE dbo.usp_E3_MedirEscrituras
    @Etiqueta VARCHAR(40),
    @Ventas   INT = 1000
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #Cand(n INT PRIMARY KEY, ViajeID INT, NumeroAsiento INT);

    INSERT #Cand(n, ViajeID, NumeroAsiento)
    SELECT TOP (@Ventas)
           ROW_NUMBER() OVER (ORDER BY v.ViajeID, s.NumeroAsiento),
           v.ViajeID, s.NumeroAsiento
    FROM dbo.Viajes v
    JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.Estado = 'Programado'
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                      WHERE b.ViajeID = v.ViajeID AND b.NumeroAsiento = s.NumeroAsiento
                        AND b.Estado = 'Activo')
    ORDER BY v.ViajeID, s.NumeroAsiento;

    DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM #Cand),
            @V INT, @A INT, @id INT, @t0 DATETIME2(7), @ms INT;

    SET @t0 = SYSDATETIME();
    BEGIN TRAN;
    WHILE @i <= @n
    BEGIN
        SELECT @V = ViajeID, @A = NumeroAsiento FROM #Cand WHERE n = @i;
        EXEC dbo.sp_VenderBoleto @V, @A, 1, 'Web', 'Tarjeta', @id OUTPUT;
        SET @i += 1;
    END
    SET @ms = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
    IF @@TRANCOUNT > 0 ROLLBACK;

    SELECT @Etiqueta AS Escenario, @n AS Ventas, @ms AS Ms_total,
           CAST(@ms * 1.0 / NULLIF(@n, 0) AS DECIMAL(10,3)) AS Ms_por_venta;
END
GO
EXEC dbo.usp_E3_MedirEscrituras @Etiqueta = 'ANTES de indices nuevos';
GO

/* =========================================================
   BLOQUE 5. CORRECCION: indices nuevos
   C1: no necesita indice nuevo; lo cubre UX_Boletos_Viaje_Asiento_Activo (E1):
       clave (ViajeID, NumeroAsiento) filtrada por Estado = 'Activo' -> Seek sin lookups.
   C2: IX_Boletos_ClienteID (clave ClienteID; INCLUDE de las columnas que se muestran)
       + la busqueda por Cedula usa el indice UQ_Clientes_Cedula de E1.
   C3: IX_Boletos_FechaVenta (rango de fechas; INCLUDE Estado y ViajeID) e
       IX_Pagos_BoletoID (union Boletos-Pagos; INCLUDE Monto para no ir a la tabla).
   ========================================================= */
CREATE NONCLUSTERED INDEX IX_Boletos_ClienteID
    ON dbo.Boletos(ClienteID)
    INCLUDE (ViajeID, NumeroAsiento, Precio, Estado);

CREATE NONCLUSTERED INDEX IX_Boletos_FechaVenta
    ON dbo.Boletos(FechaVenta)
    INCLUDE (Estado, ViajeID);

CREATE NONCLUSTERED INDEX IX_Pagos_BoletoID
    ON dbo.Pagos(BoletoID)
    INCLUDE (Monto);
GO

/* =========================================================
   BLOQUE 6. DESPUES - consultas REESCRITAS
   Ctrl+M activado. Captura: plan real + Messages.
   ========================================================= */
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

/* ---- C1 reescrita: NOT EXISTS en lugar de NOT IN ---- */
DECLARE @ViajeID INT = 16000;          -- <<< viaje asignado
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1
                  FROM dbo.Boletos b
                  WHERE b.ViajeID = @ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;
GO

/* ---- C2 reescrita: sin funciones sobre la columna (sargable) ---- */
DECLARE @Cedula CHAR(11) = '40200002000';
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE c.Cedula = @Cedula
ORDER BY v.FechaSalida DESC;
GO

/* ---- C3 reescrita: rango de fechas en lugar de YEAR() ---- */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.FechaVenta >= '20250101'
  AND b.FechaVenta <  '20260101'
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;
GO

/* =========================================================
   BLOQUE 7. Costo de ESCRITURA DESPUES de crear los indices nuevos
   (sin Ctrl+M; ejecutar 3 veces y anotar el menor tiempo)
   ========================================================= */
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
EXEC dbo.usp_E3_MedirEscrituras @Etiqueta = 'DESPUES de indices nuevos';
GO

/* =========================================================
   BLOQUE 8. Las consultas reescritas devuelven EXACTAMENTE lo mismo
   ========================================================= */
DECLARE @ViajeID INT = 16000;          -- <<< viaje asignado
DECLARE @Cedula  CHAR(11) = '40200002000';

IF OBJECT_ID('tempdb..#C1o') IS NOT NULL DROP TABLE #C1o;
IF OBJECT_ID('tempdb..#C1n') IS NOT NULL DROP TABLE #C1n;
IF OBJECT_ID('tempdb..#C2o') IS NOT NULL DROP TABLE #C2o;
IF OBJECT_ID('tempdb..#C2n') IS NOT NULL DROP TABLE #C2n;
IF OBJECT_ID('tempdb..#C3o') IS NOT NULL DROP TABLE #C3o;
IF OBJECT_ID('tempdb..#C3n') IS NOT NULL DROP TABLE #C3n;

/* C1 */
SELECT s.NumeroAsiento, s.Ubicacion INTO #C1o
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND s.NumeroAsiento NOT IN (SELECT b.NumeroAsiento FROM dbo.Boletos b
                              WHERE b.ViajeID = @ViajeID AND b.Estado = 'Activo');

SELECT s.NumeroAsiento, s.Ubicacion INTO #C1n
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = @ViajeID AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo');

/* C2 */
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
INTO #C2o
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula;

SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
INTO #C2n
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE c.Cedula = @Cedula;

/* C3 */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
INTO #C3o
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE YEAR(b.FechaVenta) = 2025 AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);

SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
INTO #C3n
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.FechaVenta >= '20250101' AND b.FechaVenta < '20260101' AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);

;WITH x AS (
    SELECT 'C1' AS Consulta,
           (SELECT COUNT(*) FROM #C1o) AS Filas_original,
           (SELECT COUNT(*) FROM #C1n) AS Filas_nueva,
           (SELECT COUNT(*) FROM (SELECT * FROM #C1o EXCEPT SELECT * FROM #C1n) a) AS Solo_en_original,
           (SELECT COUNT(*) FROM (SELECT * FROM #C1n EXCEPT SELECT * FROM #C1o) b) AS Solo_en_nueva
    UNION ALL
    SELECT 'C2',
           (SELECT COUNT(*) FROM #C2o),
           (SELECT COUNT(*) FROM #C2n),
           (SELECT COUNT(*) FROM (SELECT * FROM #C2o EXCEPT SELECT * FROM #C2n) a),
           (SELECT COUNT(*) FROM (SELECT * FROM #C2n EXCEPT SELECT * FROM #C2o) b)
    UNION ALL
    SELECT 'C3',
           (SELECT COUNT(*) FROM #C3o),
           (SELECT COUNT(*) FROM #C3n),
           (SELECT COUNT(*) FROM (SELECT * FROM #C3o EXCEPT SELECT * FROM #C3n) a),
           (SELECT COUNT(*) FROM (SELECT * FROM #C3n EXCEPT SELECT * FROM #C3o) b)
)
SELECT *,
       CASE WHEN Filas_original = Filas_nueva AND Solo_en_original = 0 AND Solo_en_nueva = 0
            THEN 'IGUALES' ELSE 'DIFERENTES' END AS Resultado
FROM x;
GO

/* =========================================================
   BLOQUE 9. Espacio que ocupan los indices (costo de almacenamiento)
   ========================================================= */
SELECT OBJECT_NAME(i.object_id) AS Tabla, i.name AS Indice,
       CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS DECIMAL(10,2)) AS MB
FROM sys.indexes i
JOIN sys.dm_db_partition_stats ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE i.object_id IN (OBJECT_ID('dbo.Boletos'), OBJECT_ID('dbo.Pagos')) AND i.type > 0
GROUP BY i.object_id, i.name
ORDER BY Tabla, MB DESC;
GO
