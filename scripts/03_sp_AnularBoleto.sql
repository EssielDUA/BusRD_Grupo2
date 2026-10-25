/* =========================================================
   BusRD - E2.5  dbo.sp_AnularBoleto
   Anula el boleto (libera el asiento) y registra el REVERSO del pago
   con monto negativo, todo en una sola transaccion.
   ========================================================= */
USE BusRD;
GO
CREATE OR ALTER PROCEDURE dbo.sp_AnularBoleto
    @BoletoID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Estado VARCHAR(10), @Neto DECIMAL(10,2), @Metodo VARCHAR(15);

    BEGIN TRY
        BEGIN TRAN;

        /* UPDLOCK sobre la fila del boleto: si dos personas anulan el mismo boleto
           a la vez, la segunda espera y luego ve que ya esta Anulado. */
        SELECT @Estado = Estado
        FROM dbo.Boletos WITH (UPDLOCK, ROWLOCK)
        WHERE BoletoID = @BoletoID;

        IF @Estado IS NULL
            THROW 50010, 'El boleto no existe.', 1;
        IF @Estado = 'Anulado'
            THROW 50011, 'El boleto ya esta anulado.', 1;

        /* Se revierte el NETO cobrado (suma de pagos del boleto) con su mismo metodo */
        SELECT @Neto = SUM(Monto) FROM dbo.Pagos WHERE BoletoID = @BoletoID;
        SELECT TOP (1) @Metodo = Metodo FROM dbo.Pagos
        WHERE BoletoID = @BoletoID ORDER BY PagoID;

        UPDATE dbo.Boletos SET Estado = 'Anulado' WHERE BoletoID = @BoletoID;

        IF ISNULL(@Neto, 0) > 0
            INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
            VALUES (@BoletoID, -@Neto, @Metodo, SYSDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        THROW;
    END CATCH
END
GO
