/* =========================================================
   BusRD - E2.4  Demo de concurrencia - SESION A (Taquilla)
   1) Cambiar @ViajeID y @Asiento (viaje PROGRAMADO y asiento libre; iguales en la sesion B)
   2) Ejecutar A con F5 y, en menos de 10 s, ejecutar B
   ========================================================= */
USE BusRD;
GO
DECLARE @ViajeID INT = 0;      -- <<< CAMBIAR: viaje Programado
DECLARE @Asiento INT = 0;      -- <<< CAMBIAR: asiento libre de ese viaje
DECLARE @id INT, @t0 DATETIME2(3) = SYSDATETIME();

BEGIN TRY
    EXEC dbo.sp_VenderBoleto
         @ViajeID = @ViajeID, @NumeroAsiento = @Asiento,
         @ClienteID = 1, @Canal = 'Taquilla', @Metodo = 'Efectivo',
         @BoletoID = @id OUTPUT, @SimularDemora = 1;

    SELECT 'SESION A' AS Sesion, 'VENTA EXITOSA' AS Resultado, @id AS BoletoID,
           NULL AS Error, @t0 AS Inicio, SYSDATETIME() AS Fin,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS Segundos;
END TRY
BEGIN CATCH
    SELECT 'SESION A' AS Sesion, 'VENTA RECHAZADA' AS Resultado, NULL AS BoletoID,
           CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE() AS Error,
           @t0 AS Inicio, SYSDATETIME() AS Fin,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS Segundos;
END CATCH
GO
