/* =========================================================
   BusRD - E2 Pruebas de validaciones, atomicidad y anulacion
   Escoge solo un viaje Programado y un asiento libre.
   Deja el asiento libre al terminar (la venta de prueba queda Anulada con reverso).
   Se ejecuta COMPLETO de una vez (F5) y muestra una sola tabla de resultados.
   ========================================================= */
USE BusRD;
GO
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
CREATE TABLE #R(Prueba VARCHAR(70), Esperado INT, Obtenido INT, Mensaje NVARCHAR(400));

DECLARE @V INT, @Bus INT, @A INT, @VC INT, @id INT, @id2 INT;

SELECT TOP (1) @V = ViajeID, @Bus = AutobusID
FROM dbo.Viajes WHERE Estado = 'Programado'
ORDER BY FechaSalida DESC, ViajeID;

SELECT TOP (1) @A = s.NumeroAsiento
FROM dbo.Asientos s
WHERE s.AutobusID = @Bus
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = @V AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento DESC;

SELECT TOP (1) @VC = ViajeID FROM dbo.Viajes WHERE Estado = 'Completado';

/* ---------- Validaciones de sp_VenderBoleto ---------- */
BEGIN TRY
    EXEC dbo.sp_VenderBoleto 99999999, @A, 1, 'Web', 'Tarjeta', @id OUTPUT;
    INSERT #R VALUES ('T1 viaje inexistente', 50003, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T1 viaje inexistente', 50003, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

BEGIN TRY
    EXEC dbo.sp_VenderBoleto @VC, @A, 1, 'Web', 'Tarjeta', @id OUTPUT;
    INSERT #R VALUES ('T2 viaje no Programado', 50004, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T2 viaje no Programado', 50004, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, 999, 1, 'Web', 'Tarjeta', @id OUTPUT;
    INSERT #R VALUES ('T3 asiento inexistente en el bus', 50005, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T3 asiento inexistente en el bus', 50005, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, @A, 99999999, 'Web', 'Tarjeta', @id OUTPUT;
    INSERT #R VALUES ('T4 cliente inexistente', 50006, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T4 cliente inexistente', 50006, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, @A, 1, 'Fax', 'Tarjeta', @id OUTPUT;
    INSERT #R VALUES ('T5 canal invalido', 50001, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T5 canal invalido', 50001, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, @A, 1, 'Web', 'Bitcoin', @id OUTPUT;
    INSERT #R VALUES ('T6 metodo invalido', 50002, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T6 metodo invalido', 50002, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

/* ---------- Venta valida: boleto y pago en la misma transaccion ---------- */
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, @A, 1, 'Taquilla', 'Efectivo', @id OUTPUT;
    INSERT #R VALUES ('T7 venta valida', 0, 0, 'BoletoID generado = ' + CAST(@id AS VARCHAR(10)));
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T7 venta valida', 0, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

INSERT #R
SELECT 'T7b boleto Activo con su pago creado', 1, COUNT(*), ''
FROM dbo.Boletos b JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
WHERE b.BoletoID = @id AND b.Estado = 'Activo';

/* ---------- Asiento ya vendido ---------- */
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, @A, 2, 'Web', 'Tarjeta', @id2 OUTPUT;
    INSERT #R VALUES ('T8 asiento ya vendido', 50007, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T8 asiento ya vendido', 50007, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

/* ---------- sp_AnularBoleto ---------- */
BEGIN TRY
    EXEC dbo.sp_AnularBoleto @id;
    INSERT #R VALUES ('T9 anular boleto', 0, 0, 'OK');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T9 anular boleto', 0, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

INSERT #R
SELECT 'T9b boleto quedo Anulado', 1, COUNT(*), ''
FROM dbo.Boletos WHERE BoletoID = @id AND Estado = 'Anulado';

INSERT #R
SELECT 'T9c neto de pagos del boleto anulado = 0', 0, CAST(ISNULL(SUM(Monto), 0) AS INT),
       'Pagos: ' + CAST(COUNT(*) AS VARCHAR(5)) + ' (cobro + reverso)'
FROM dbo.Pagos WHERE BoletoID = @id;

BEGIN TRY
    EXEC dbo.sp_AnularBoleto @id;
    INSERT #R VALUES ('T10 anular de nuevo', 50011, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T10 anular de nuevo', 50011, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

BEGIN TRY
    EXEC dbo.sp_AnularBoleto 99999999;
    INSERT #R VALUES ('T11 anular boleto inexistente', 50010, 0, 'SIN ERROR');
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T11 anular boleto inexistente', 50010, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

/* ---------- Un boleto anulado libera el asiento ---------- */
SET @id2 = NULL;
BEGIN TRY
    EXEC dbo.sp_VenderBoleto @V, @A, 2, 'Web', 'Tarjeta', @id2 OUTPUT;
    INSERT #R VALUES ('T12 reventa del asiento liberado', 0, 0, 'BoletoID generado = ' + CAST(@id2 AS VARCHAR(10)));
END TRY
BEGIN CATCH
    INSERT #R VALUES ('T12 reventa del asiento liberado', 0, ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH

-- limpieza: deja el asiento libre otra vez
IF @id2 IS NOT NULL EXEC dbo.sp_AnularBoleto @id2;

SELECT Prueba, Esperado, Obtenido,
       CASE WHEN Esperado = Obtenido THEN 'OK' ELSE 'FALLO' END AS Resultado,
       Mensaje
FROM #R;
GO
