/* =========================================================
   BusRD - E1. Integridad del modelo
   Ejecutar sobre una base recién creada con 01_BusRD_base.sql
   (la prueba de doble venta con sp_VenderBoleto_v0 se hace ANTES de este script)
   ========================================================= */
USE BusRD;
GO

/* =========================================================
   PASO 1. DETECCION DE DATOS SUCIOS
   ========================================================= */

-- 1.1 Boletos ACTIVOS duplicados (mismo viaje y mismo asiento)
SELECT ViajeID, NumeroAsiento, COUNT(*) AS Cantidad
FROM dbo.Boletos
WHERE Estado = 'Activo'
GROUP BY ViajeID, NumeroAsiento
HAVING COUNT(*) > 1
ORDER BY ViajeID, NumeroAsiento;

SELECT COUNT(*) AS GruposDuplicados
FROM (SELECT ViajeID, NumeroAsiento
      FROM dbo.Boletos
      WHERE Estado = 'Activo'
      GROUP BY ViajeID, NumeroAsiento
      HAVING COUNT(*) > 1) x;

-- 1.2 Pagos huérfanos (su boleto no existe)
SELECT p.PagoID, p.BoletoID, p.Monto, p.Metodo, p.FechaPago
FROM dbo.Pagos p
LEFT JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID
WHERE b.BoletoID IS NULL;

-- 1.3 Otras comprobaciones previas a crear FK y CHECK
SELECT 'Boleto sin viaje' AS Problema, COUNT(*) AS Filas
FROM dbo.Boletos b
WHERE NOT EXISTS (SELECT 1 FROM dbo.Viajes v WHERE v.ViajeID = b.ViajeID)
UNION ALL
SELECT 'Boleto sin cliente', COUNT(*)
FROM dbo.Boletos b
WHERE NOT EXISTS (SELECT 1 FROM dbo.Clientes c WHERE c.ClienteID = b.ClienteID)
UNION ALL
SELECT 'Boleto con asiento inexistente en el bus', COUNT(*)
FROM dbo.Boletos b
JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID
WHERE NOT EXISTS (SELECT 1 FROM dbo.Asientos s
                  WHERE s.AutobusID = v.AutobusID AND s.NumeroAsiento = b.NumeroAsiento)
UNION ALL
SELECT 'Boleto activo en viaje Cancelado', COUNT(*)
FROM dbo.Boletos b
JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID
WHERE v.Estado = 'Cancelado' AND b.Estado = 'Activo'
UNION ALL
SELECT 'Pago con monto distinto al precio del boleto', COUNT(*)
FROM dbo.Pagos p
JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID
WHERE p.Monto <> b.Precio
UNION ALL
SELECT 'Boleto con mas de un pago', COUNT(*)
FROM (SELECT BoletoID FROM dbo.Pagos GROUP BY BoletoID HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'Boleto activo sin pago', COUNT(*)
FROM dbo.Boletos b
WHERE b.Estado = 'Activo'
  AND NOT EXISTS (SELECT 1 FROM dbo.Pagos p WHERE p.BoletoID = b.BoletoID);
GO

/* =========================================================
   PASO 2. LIMPIEZA (en una sola transacción)
   Reglas:
   - Duplicados: se conserva el boleto activo MAS ANTIGUO (prioridad legítima
     sobre el asiento) y se ANULAN los posteriores. No se borra nada.
   - Pago del boleto anulado: no se borra; se inserta un REVERSO con monto
     negativo (neto = 0), para conservar la trazabilidad financiera.
   - Pagos huérfanos: no tienen boleto al que asociarse; se mueven a una tabla
     de cuarentena y se eliminan de Pagos para poder crear la FK.
   ========================================================= */
SET XACT_ABORT ON;
GO
BEGIN TRY
BEGIN TRAN;

/* 2.1 Pagos huérfanos -> cuarentena */
IF OBJECT_ID('dbo.Pagos_Huerfanos') IS NULL
CREATE TABLE dbo.Pagos_Huerfanos(
    PagoID          INT           NOT NULL,
    BoletoID        INT           NOT NULL,
    Monto           DECIMAL(10,2) NOT NULL,
    Metodo          VARCHAR(15)   NOT NULL,
    FechaPago       DATETIME2(0)  NOT NULL,
    FechaCuarentena DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    Motivo          VARCHAR(100)  NOT NULL DEFAULT 'Pago sin boleto asociado'
);

DELETE p
OUTPUT deleted.PagoID, deleted.BoletoID, deleted.Monto, deleted.Metodo, deleted.FechaPago
INTO dbo.Pagos_Huerfanos(PagoID, BoletoID, Monto, Metodo, FechaPago)
FROM dbo.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID);

/* 2.2 Bitácora de duplicados: cuál se anula y cuál se conserva */
IF OBJECT_ID('dbo.Limpieza_Duplicados') IS NULL
CREATE TABLE dbo.Limpieza_Duplicados(
    BoletoAnuladoID    INT          NOT NULL,
    BoletoConservadoID INT          NOT NULL,
    ViajeID            INT          NOT NULL,
    NumeroAsiento      INT          NOT NULL,
    Fecha              DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

;WITH x AS (
    SELECT BoletoID, ViajeID, NumeroAsiento,
           ROW_NUMBER()  OVER (PARTITION BY ViajeID, NumeroAsiento
                               ORDER BY FechaVenta, BoletoID) AS rn,
           FIRST_VALUE(BoletoID) OVER (PARTITION BY ViajeID, NumeroAsiento
                               ORDER BY FechaVenta, BoletoID) AS Conservado
    FROM dbo.Boletos
    WHERE Estado = 'Activo'
)
INSERT dbo.Limpieza_Duplicados(BoletoAnuladoID, BoletoConservadoID, ViajeID, NumeroAsiento)
SELECT BoletoID, Conservado, ViajeID, NumeroAsiento
FROM x
WHERE rn > 1;

/* 2.3 Reverso (monto negativo) del pago de cada boleto que se anula */
INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
SELECT p.BoletoID, -p.Monto, p.Metodo, SYSDATETIME()
FROM dbo.Limpieza_Duplicados d
JOIN dbo.Pagos p ON p.BoletoID = d.BoletoAnuladoID
WHERE p.Monto > 0;

/* 2.4 Anular los boletos duplicados */
UPDATE b
SET Estado = 'Anulado'
FROM dbo.Boletos b
JOIN dbo.Limpieza_Duplicados d ON d.BoletoAnuladoID = b.BoletoID;

COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH
GO

/* =========================================================
   PASO 3. LLAVES FORANEAS
   Nota: Boletos no puede tener FK hacia Asientos porque no guarda AutobusID.
   Esa validación (asiento pertenece al autobús del viaje) la hace sp_VenderBoleto.
   ========================================================= */
ALTER TABLE dbo.Asientos WITH CHECK ADD CONSTRAINT FK_Asientos_Autobuses
    FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Viajes   WITH CHECK ADD CONSTRAINT FK_Viajes_Rutas
    FOREIGN KEY (RutaID)    REFERENCES dbo.Rutas(RutaID);
ALTER TABLE dbo.Viajes   WITH CHECK ADD CONSTRAINT FK_Viajes_Autobuses
    FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Boletos  WITH CHECK ADD CONSTRAINT FK_Boletos_Viajes
    FOREIGN KEY (ViajeID)   REFERENCES dbo.Viajes(ViajeID);
ALTER TABLE dbo.Boletos  WITH CHECK ADD CONSTRAINT FK_Boletos_Clientes
    FOREIGN KEY (ClienteID) REFERENCES dbo.Clientes(ClienteID);
ALTER TABLE dbo.Pagos    WITH CHECK ADD CONSTRAINT FK_Pagos_Boletos
    FOREIGN KEY (BoletoID)  REFERENCES dbo.Boletos(BoletoID);
GO

/* =========================================================
   PASO 4. RESTRICCIONES CHECK (dominio y rango)
   Pagos.Monto permite negativos porque el reverso de un pago es negativo.
   ========================================================= */
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Tipo
    CHECK (Tipo IN ('Estandar','Ejecutivo'));
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Capacidad
    CHECK (Capacidad BETWEEN 1 AND 60);
ALTER TABLE dbo.Asientos  WITH CHECK ADD CONSTRAINT CK_Asientos_Ubicacion
    CHECK (Ubicacion IN ('Ventana','Pasillo'));
ALTER TABLE dbo.Viajes    WITH CHECK ADD CONSTRAINT CK_Viajes_Estado
    CHECK (Estado IN ('Programado','Completado','Cancelado'));
ALTER TABLE dbo.Rutas     WITH CHECK ADD CONSTRAINT CK_Rutas_Distancia
    CHECK (DistanciaKm > 0);
ALTER TABLE dbo.Rutas     WITH CHECK ADD CONSTRAINT CK_Rutas_PrecioBase
    CHECK (PrecioBase > 0);
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Estado
    CHECK (Estado IN ('Activo','Anulado'));
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Canal
    CHECK (Canal IN ('Taquilla','Web'));
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Precio
    CHECK (Precio > 0 AND Precio <= 50000);
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Asiento
    CHECK (NumeroAsiento > 0);
ALTER TABLE dbo.Pagos     WITH CHECK ADD CONSTRAINT CK_Pagos_Metodo
    CHECK (Metodo IN ('Efectivo','Tarjeta','Transferencia'));
ALTER TABLE dbo.Pagos     WITH CHECK ADD CONSTRAINT CK_Pagos_Monto
    CHECK (Monto <> 0 AND Monto BETWEEN -50000 AND 50000);
GO

/* =========================================================
   PASO 5. UNICIDAD
   ========================================================= */
ALTER TABLE dbo.Clientes  ADD CONSTRAINT UQ_Clientes_Cedula UNIQUE (Cedula);
ALTER TABLE dbo.Autobuses ADD CONSTRAINT UQ_Autobuses_Placa UNIQUE (Placa);
GO

/* Un asiento de un viaje solo puede tener UN boleto ACTIVO.
   Un boleto anulado queda fuera del índice y libera el asiento. */
CREATE UNIQUE NONCLUSTERED INDEX UX_Boletos_Viaje_Asiento_Activo
ON dbo.Boletos(ViajeID, NumeroAsiento)
WHERE Estado = 'Activo';
GO

/* =========================================================
   PASO 6. VERIFICACION
   ========================================================= */

-- 6.1 Controles de limpieza
SELECT 'Duplicados activos restantes' AS Control, COUNT(*) AS Filas
FROM (SELECT 1 AS x FROM dbo.Boletos WHERE Estado = 'Activo'
      GROUP BY ViajeID, NumeroAsiento HAVING COUNT(*) > 1) z
UNION ALL
SELECT 'Pagos huerfanos restantes', COUNT(*)
FROM dbo.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID)
UNION ALL
SELECT 'En cuarentena', COUNT(*) FROM dbo.Pagos_Huerfanos
UNION ALL
SELECT 'Boletos anulados por duplicado', COUNT(*) FROM dbo.Limpieza_Duplicados
UNION ALL
SELECT 'Neto de pagos de anulados por duplicado (debe ser 0)', ISNULL(SUM(p.Monto), 0)
FROM dbo.Pagos p
JOIN dbo.Limpieza_Duplicados d ON d.BoletoAnuladoID = p.BoletoID;

-- 6.2 Restricciones creadas (esperado: 6 FK, 12 CHECK, 2 UNIQUE, 1 indice filtrado)
SELECT 'FK' AS Tipo, name FROM sys.foreign_keys
UNION ALL SELECT 'CHECK', name FROM sys.check_constraints
UNION ALL SELECT 'UNIQUE', name FROM sys.key_constraints WHERE type = 'UQ'
UNION ALL SELECT 'INDICE UNICO FILTRADO', name FROM sys.indexes
          WHERE name = 'UX_Boletos_Viaje_Asiento_Activo';

-- 6.3 Prueba: la base rechaza un segundo boleto activo para el mismo asiento
--     (toma un asiento ya vendido y trata de venderlo otra vez; debe dar error 2601)
DECLARE @V INT, @A INT;
SELECT TOP (1) @V = ViajeID, @A = NumeroAsiento
FROM dbo.Boletos WHERE Estado = 'Activo' ORDER BY BoletoID;

BEGIN TRY
    INSERT dbo.Boletos(ViajeID,NumeroAsiento,ClienteID,FechaVenta,Canal,Precio,Estado)
    VALUES (@V, @A, 3, SYSDATETIME(), 'Web', 420, 'Activo');
    SELECT 'ERROR: el duplicado fue aceptado' AS Resultado;
END TRY
BEGIN CATCH
    SELECT 'Duplicado rechazado correctamente' AS Resultado,
           ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
END CATCH
GO
