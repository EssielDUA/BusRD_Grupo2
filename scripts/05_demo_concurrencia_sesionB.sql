/* =========================================================
   BusRD - E2.4  Demo de concurrencia - SESION B (Web)
   Mismos @ViajeID y @Asiento que la sesion A.
   Se ejecuta unos segundos DESPUES de A (menos de 10 s).
   Resultado esperado: B espera a que A termine y es RECHAZADA con el error 50007.
   ========================================================= */
USE BusRD;
GO
DECLARE @ViajeID INT = 0;      -- <<< CAMBIAR: igual que en la sesion A
DECLARE @Asiento INT = 0;      -- <<< CAMBIAR: igual que en la sesion A
DECLARE @id INT, @t0 DATETIME2(3) = SYSDATETIME();

BEGIN TRY
    EXEC dbo.sp_VenderBoleto
         @ViajeID = @ViajeID, @NumeroAsiento = @Asiento,
         @ClienteID = 2, @Canal = 'Web', @Metodo = 'Tarjeta',
         @BoletoID = @id OUTPUT, @SimularDemora = 1;

    SELECT 'SESION B' AS Sesion, 'VENTA EXITOSA' AS Resultado, @id AS BoletoID,
           NULL AS Error, @t0 AS Inicio, SYSDATETIME() AS Fin,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS Segundos;
END TRY
BEGIN CATCH
    SELECT 'SESION B' AS Sesion, 'VENTA RECHAZADA' AS Resultado, NULL AS BoletoID,
           CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE() AS Error,
           @t0 AS Inicio, SYSDATETIME() AS Fin,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS Segundos;
END CATCH
GO

/* ---------------------------------------------------------
   EVIDENCIAS (ejecutar en una TERCERA pestana, seleccionando solo la consulta)

   -- (1) MIENTRAS A y B corren: B bloqueada por A
   SELECT session_id, blocking_session_id, wait_type, wait_time, status
   FROM sys.dm_exec_requests
   WHERE blocking_session_id <> 0;

   -- (2) AL TERMINAR: debe haber UN solo boleto activo, con su pago
   SELECT b.BoletoID, b.ClienteID, b.Canal, b.Estado, p.Monto, p.Metodo
   FROM dbo.Boletos b LEFT JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
   WHERE b.ViajeID = <VIAJE> AND b.NumeroAsiento = <ASIENTO>;
   --------------------------------------------------------- */
