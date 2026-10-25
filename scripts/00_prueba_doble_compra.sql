--Primera Compra
USE BusRD;
EXEC dbo.sp_VenderBoleto_v0
     @ViajeID = 16000, @NumeroAsiento = 30,
     @ClienteID = 2, @Canal = 'Web', @Metodo = 'Tarjeta';

--Segunda Compra
USE BusRD;
EXEC dbo.sp_VenderBoleto_v0
     @ViajeID = 16000, @NumeroAsiento = 30,
     @ClienteID = 1, @Canal = 'Taquilla', @Metodo = 'Efectivo';

--Visualizar conflicto de ambas compras

USE BusRD;
SELECT b.BoletoID, b.ViajeID, b.NumeroAsiento, b.ClienteID, b.Canal, b.Estado, b.FechaVenta
FROM dbo.Boletos b
WHERE b.ViajeID = 16000 AND b.NumeroAsiento = 30;
