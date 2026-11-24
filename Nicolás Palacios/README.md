# Asesores Expertos NP — Niveles de soporte y resistencia (MQL5)

Dos Asesores Expertos (EA) independientes para MetaTrader 5, derivados del EA original `NP Estrategia`. Ambos comparten el mismo motor de detección de soportes y resistencias, pero implementan estrategias distintas.

| Archivo | Estrategia |
|---|---|
| `NP_StopLossEstructural.mq5` | Compras de largo plazo sobre soportes, evaluadas **al tick**, con SL y TP estructurales. |
| `NP_Niveles.mq5` | Compras y ventas sobre niveles, evaluadas **al cierre de vela**, con confirmación de volumen y SL/TP por ATR. |

## Comparación rápida

| | NP_StopLossEstructural | NP_Niveles |
|---|---|---|
| Dirección | Solo compras | Compras y ventas |
| Evaluación | En cada tick | Solo al formarse una vela nueva |
| Condición de entrada | El precio (Ask) entra en la zona de un soporte, con la vela abierta sobre el soporte | La vela señal toca el nivel, **abre y cierra** del lado correcto, y su volumen supera el promedio |
| Confirmación de volumen | No | Sí (obligatoria) |
| Filtro RSI(14) | Sí, fijo: RSI > 70 no compra | Sí, fijo: RSI > 70 no compra, RSI < 30 no vende |
| Filtro de tendencia (EMA) | No | Opcional |
| Stop Loss | Estructural (obligatorio) | Por ATR |
| Take Profit | Estructural (opcional) | Por ATR |
| Trailing stop | Sí (por defecto activo) | Opcional (por defecto apagado) |
| Break even | No | Opcional (por defecto apagado) |
| Magic number por defecto | 555111 | 555112 |
| Prefijo de objetos / log | `NPSL_` / `NP_SLE` | `NPNV_` / `NP_NIV` |

Los prefijos y magic numbers distintos permiten correr ambos EAs en el mismo símbolo sin que se pisen.

## Cómo se obtienen los niveles

Los niveles **no** se leen de objetos del gráfico ni de buffers de indicador: se calculan dentro del EA y las líneas horizontales del gráfico solo los dibujan.

1. Se recorren las temporalidades de la base hacia arriba (M5, M15, M30, H1, H4, D1; solo las superiores a la base, más la propia base).
2. En cada una se toman los máximos y mínimos de las últimas `InpBarsToAnalyze` velas cerradas.
3. Una estimación de densidad por kernel (KDE) detecta zonas de concentración.
4. Cada zona se ajusta por mínimos cuadrados ponderados y recibe un **puntaje** (**menor = mejor nivel**).
5. Los niveles de distintas temporalidades se fusionan por confluencia y se seleccionan los mejores, separados por una distancia mínima.
6. Todo se recalcula al abrir cada vela de la temporalidad base. Un nivel por encima del cierre anterior es resistencia; por debajo, soporte.

Mientras alguna temporalidad no tenga historial suficiente, el EA no opera ni dibuja. Pasando el mouse por una línea se ve su tooltip con precio, toques, temporalidades y puntaje.

## Funciones comunes

- **Filtro de puntaje (`InpMaxLevelScore`)**: se omiten los niveles con puntaje **mayor o igual** al valor indicado. `0` significa sin filtro. Las líneas siguen dibujadas; solo se excluyen de las entradas. No genera aviso en el log.
- **Filtro RSI(14) integrado**: no es configurable. Se calcula sobre la última vela cerrada de la temporalidad base. Cada operación omitida por este motivo deja un `Print()` con el valor del RSI y el nivel (en `NP_StopLossEstructural`, como máximo uno por vela).
- **Lotaje**: fijo (`LOT_MODE_FIXED`) o por % de riesgo (`LOT_MODE_RISK_PERCENT`, sobre el menor entre balance y equity, hasta el SL). `InpMaxTotalRiskPercent` limita el riesgo conjunto de todas las posiciones propias. Si el lote por riesgo queda bajo el mínimo del símbolo, la operación se omite.
- **Protecciones de entrada**: máximo de posiciones simultáneas, distancia mínima entre entradas, spread máximo (en ATR), espera por nivel (`InpLevelCooldownBars`), distancia mínima de stops del bróker y verificación de margen libre.
- **Optimización**: `OnTester` devuelve el factor de recuperación (beneficio / drawdown máximo de equity); las pasadas con menos de `InpTesterMinTrades` operaciones puntúan 0.

## NP_StopLossEstructural

Estrategia alcista de largo plazo. Compra en cuanto el precio toca la zona de un soporte, sin esperar el cierre de la vela.

- **SL estructural** (obligatorio), en `InpStructuralSLMode`:
  - `STRUCT_SL_AUTO` (por defecto): el modelo calcula el SL más alto cuya probabilidad de ser tocado dentro de `InpStructSlHorizonBars` velas no supera `InpStructSlMaxTouchProb` (5 % por defecto). Se calcula sobre temporalidad semanal (`InpStructSlTimeframe`) combinando un modelo browniano con la frecuencia empírica histórica.
  - `STRUCT_SL_MANUAL`: usa `InpStructuralSLPrice`, un precio absoluto que **depende del símbolo** (el valor por defecto, 30000, es solo un ejemplo).
  - Si el SL queda por encima del precio de entrada, la operación se omite.
- **TP estructural** (`InpUseStructuralTP`, por defecto activo): la resistencia más cercana por encima del precio de entrada cuyo puntaje es **menor** (mejor) que el del soporte operado. Si ninguna cumple, la operación se omite. Con el TP desactivado, la operación abre sin TP. Con el TP activo, `InpMaxLinesAbove` debe ser mayor que 0.
- **Trailing stop** (`InpUseTrailingStop`): una vez que la ganancia supera `InpTrailingTriggerAtrMultiplier` × ATR, el SL sigue al precio a `InpTrailingAtrMultiplier` × ATR. Solo mueve el SL a favor de la posición.

## NP_Niveles

Opera el rechazo confirmado de un nivel, al cierre de vela. La señal se evalúa sobre la vela recién cerrada.

Para **compra**, el soporte debe cumplir todo lo siguiente:

1. La vela abrió sobre el soporte, lo tocó con la mecha (dentro de la tolerancia) y cerró sobre él.
2. Su volumen es mayor que el promedio simple de las `InpVolumePeriod` velas anteriores a ella (20 por defecto; la vela señal no entra en el promedio). Usa volumen real si el símbolo lo provee, y volumen de ticks en caso contrario.
3. El RSI(14) no es mayor que 70.

Para **venta**, es lo simétrico: la vela abre bajo la resistencia, la toca y cierra bajo ella, con el mismo filtro de volumen y RSI(14) no menor que 30.

- **Filtro de tendencia** (`InpUseTrendFilter`, por defecto apagado): con el filtro activo, solo se compra si la pendiente de la EMA (`InpTrendEmaPeriod`, 200 por defecto) es alcista y solo se vende si es bajista. En mercado lateral no se opera.
- **Salida**: SL y TP como múltiplos de ATR (`InpSlAtrMultiplier`, `InpTpAtrMultiplier`). Break even y trailing son opcionales.
- Si ambos lados tocan en la misma vela, se elige el nivel de mejor puntaje, después de aplicar el filtro RSI a cada lado.

## Instalación

1. Copiar los `.mq5` a la carpeta `MQL5\Experts` del terminal (menú *Archivo → Abrir carpeta de datos*).
2. Compilar con MetaEditor (F7). Los archivos compilan sin errores ni warnings. Solo dependen de `Trade\Trade.mqh`, de la librería estándar. Los `.ex5` incluidos en el repo se pueden usar directamente.
3. Arrastrar el EA al gráfico del símbolo y activar el trading algorítmico.

## Requisitos y consideraciones

- **Cuenta de cobertura (hedging)**: con `InpMaxOpenPositions > 1` (por defecto 50) el EA exige una cuenta de cobertura y falla en `OnInit` si la cuenta es de netting. Con una cuenta de netting, usa `InpMaxOpenPositions = 1`.
- **Historial**: cada temporalidad necesita al menos `InpBarsToAnalyze` + 2 velas descargadas. El SL estructural automático necesita además, como mínimo, `InpStructSlHorizonBars` + 52 velas de su temporalidad (104 semanas por defecto) y usa hasta `InpStructSlLookbackBars` (520).
- **Defaults provisionales**: los valores por defecto de ambos EAs son en gran parte los del original y no están optimizados. Revísalos y pruébalos en el Probador de estrategias antes de usarlos con dinero real.
- **Validaciones**: ante una configuración inválida (por ejemplo `LOT_MODE_RISK_PERCENT` sin SL activo, o `InpMaxTotalRiskPercent` menor que `InpRiskPercent`), el EA falla en `OnInit` con un mensaje en la pestaña *Expertos*.
- **Logs**: con `InpVerboseLog` activo, cada recálculo imprime los niveles seleccionados y los motivos de las entradas omitidas. Con muchas posiciones y evaluación al tick, puede producir bastante salida.

## Aviso

Este software se entrega con fines educativos y de investigación. Operar en mercados financieros implica riesgo de pérdida de capital. Prueba en cuenta demo antes de usar capital real.
