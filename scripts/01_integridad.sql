USE BusRD;
-- Asientos con más de un boleto ACTIVO en el mismo viaje
SELECT ViajeID, NumeroAsiento, COUNT(*) AS Cantidad
FROM dbo.Boletos
WHERE Estado = 'Activo'
GROUP BY ViajeID, NumeroAsiento
HAVING COUNT(*) > 1
ORDER BY ViajeID, NumeroAsiento;
