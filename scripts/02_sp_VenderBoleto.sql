/* =========================================================
   BusRD - E2.3  dbo.sp_VenderBoleto
   Requiere haber ejecutado antes 01_integridad.sql
   ========================================================= */
USE BusRD;
GO
CREATE OR ALTER PROCEDURE dbo.sp_VenderBoleto
    @ViajeID        INT,
    @NumeroAsiento  INT,
    @ClienteID      INT,
    @Canal          VARCHAR(10),
    @Metodo         VARCHAR(15),
    @BoletoID       INT OUTPUT,          -- BoletoID generado
    @SimularDemora  BIT = 0              -- 1 = WAITFOR 10 s dentro de la transaccion (demo)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                   -- cualquier error aborta y revierte la transaccion

    DECLARE @AutobusID INT, @EstadoViaje VARCHAR(15), @Precio DECIMAL(10,2);
    SET @BoletoID = NULL;

    /* ---- Validaciones que no necesitan leer tablas ---- */
    IF @Canal IS NULL OR @Canal NOT IN ('Taquilla','Web')
        THROW 50001, 'Canal invalido. Use Taquilla o Web.', 1;
    IF @Metodo IS NULL OR @Metodo NOT IN ('Efectivo','Tarjeta','Transferencia')
        THROW 50002, 'Metodo de pago invalido. Use Efectivo, Tarjeta o Transferencia.', 1;

    BEGIN TRY
        BEGIN TRAN;

        /* ---- Viaje y precio. HOLDLOCK conserva el candado hasta el COMMIT:
               nadie cambia el estado del viaje mientras se cobra ---- */
        SELECT @AutobusID = v.AutobusID, @EstadoViaje = v.Estado, @Precio = r.PrecioBase
        FROM dbo.Viajes v WITH (HOLDLOCK)
        JOIN dbo.Rutas  r ON r.RutaID = v.RutaID
        WHERE v.ViajeID = @ViajeID;

        IF @AutobusID IS NULL
            THROW 50003, 'El viaje no existe.', 1;
        IF @EstadoViaje <> 'Programado'
            THROW 50004, 'El viaje no esta Programado.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Asientos
                       WHERE AutobusID = @AutobusID AND NumeroAsiento = @NumeroAsiento)
            THROW 50005, 'El asiento no existe en el autobus de este viaje.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE ClienteID = @ClienteID)
            THROW 50006, 'El cliente no existe.', 1;

        /* ---- Verificacion de disponibilidad CON CANDADO ----
           UPDLOCK : candado de actualizacion; el segundo vendedor espera aqui
                     (evita el deadlock de dos candados compartidos).
           HOLDLOCK: equivale a SERIALIZABLE en esta lectura; bloquea el RANGO de la
                     clave (ViajeID, NumeroAsiento) aunque la fila aun no exista,
                     eliminando la lectura fantasma hasta el COMMIT. ---- */
        IF EXISTS (SELECT 1 FROM dbo.Boletos WITH (UPDLOCK, HOLDLOCK)
                   WHERE ViajeID = @ViajeID
                     AND NumeroAsiento = @NumeroAsiento
                     AND Estado = 'Activo')
            THROW 50007, 'El asiento ya esta vendido.', 1;

        IF @SimularDemora = 1
            WAITFOR DELAY '00:00:10';    -- simula el cobro, DENTRO de la transaccion

        INSERT dbo.Boletos(ViajeID, NumeroAsiento, ClienteID, FechaVenta, Canal, Precio, Estado)
        VALUES (@ViajeID, @NumeroAsiento, @ClienteID, SYSDATETIME(), @Canal, @Precio, 'Activo');

        SET @BoletoID = SCOPE_IDENTITY();

        INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
        VALUES (@BoletoID, @Precio, @Metodo, SYSDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        SET @BoletoID = NULL;
        THROW;                           -- relanza el error original al llamador
    END CATCH
END
GO
