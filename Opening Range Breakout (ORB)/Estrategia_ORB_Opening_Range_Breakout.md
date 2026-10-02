# Estrategia de Ruptura del Rango de Apertura (ORB — Opening Range Breakout)

## 1. Qué es

ORB es estrategia intradía. Define rango (máximo/mínimo) en primeros minutos de sesión, luego opera ruptura de ese rango. Origen: libro de Toby Crabel, 1990 ("Day Trading With Short Term Price Patterns And Opening Range Breakout").

Lógica: apertura concentra órdenes institucionales grandes → genera momentum direccional. Rango inicial = "compresión" de volatilidad nocturna; ruptura = liberación de esa energía.

## 2. Definición del rango de apertura

- Marcar máximo (ORH) y mínimo (ORL) de los primeros N minutos tras apertura.
- Ventanas más usadas:

| Ventana | Características | Mejor uso |
|---|---|---|
| 5 min | Señales rápidas, rango angosto, más ruido | Scalping en futuros líquidos |
| 15 min | Balance rapidez/fiabilidad | Day trading general |
| 30 min | Más estudiada, estándar de facto | Day trading general (recomendada para empezar) |
| 60 min | Rango ancho, pocas señales, más estable (también llamado "Initial Balance") | Intradía tipo swing |

- Regla base: esperar a que el rango se forme completo antes de operar (no anticipar).

### Rango por temporalidad (multi-timeframe)

El rango se toma de una vela de la **temporalidad de rango** (M15, M30, H1, D1…) y las rupturas se confirman en una **temporalidad de confirmación** menor o igual (p. ej. rango D1, confirmación M15). Solo se evalúan velas de confirmación cerradas.

La vela de rango se elige respecto de la **hora de operación** (por defecto 9:30 NY):

| Vela | Definición | Ejemplo | Operable desde |
|---|---|---|---|
| Anterior | Última vela cerrada antes de la hora de operación | D1 → máximo/mínimo del día previo (PDH/PDL) | Hora de operación |
| Actual, abre a la hora de operación | Vela completa que abre a esa hora (ORB clásico) | M30 → 9:30–10:00 NY | Cierre de esa vela |
| Actual, abrió antes | Máximo/mínimo formado desde su apertura hasta la hora de operación | D1 → rango Asia + Londres hasta 9:30 NY | Hora de operación |

Para eventos de ruptura solo cuentan las velas posteriores a que el rango está listo, y se requiere un cruce (la vela previa cerró del otro lado del nivel).

## 3. Reglas de entrada

- **Largo**: precio rompe por encima de ORH. Confirmación recomendada: cierre de vela completa por encima del nivel (no solo mecha), idealmente con volumen por encima del promedio.
- **Corto**: precio rompe por debajo de ORL, mismas condiciones de confirmación.
- Filtros opcionales para reducir falsas rupturas:
  - Volumen: exigir pico de volumen en la vela de ruptura.
  - Volatilidad: solo operar si ATR del día supera un umbral (evita días muertos).
  - Tendencia: alinear con sesgo de gap o tendencia previa.
  - Ancho del rango vs ATR: descartar rangos anormalmente angostos o anchos.

### Variantes de setup (de más a menos agresivas)

1. **Ruptura limpia**: entrar directo en la ruptura de ORH/ORL.
2. **Retest**: esperar que el precio rompa, retroceda a testear el nivel roto como soporte/resistencia, y entrar ahí con límite. Suele considerarse el setup de mayor probabilidad porque confirma el nivel.
3. **Fade de falsa ruptura**: si rompe y vuelve a meterse dentro del rango, operar el regreso (mean reversion), capturando el cierre de posiciones atrapadas.
4. **Rebote en el lado opuesto del rango**: en mercado lateral, comprar en ORL con stop debajo, buscando ORH.

### Setups implementados en el EA

El EA ofrece tres setups (input `InpSetup`). Todos se evalúan al cierre de la vela de confirmación.

**1. Ruptura limpia (Breakout)** — variante 1.
- Compra: una vela cierra por encima de ORH tras haber cerrado la anterior dentro del rango.
- Venta: una vela cierra por debajo de ORL, misma condición.

**2. Liquidity Sweep** — variante 3 (fade de falsa ruptura). Se opera **contra** la ruptura.
- El precio rompe el rango **con cuerpo** (cierre fuera) para barrer la liquidez de los stops y luego vuelve a entrar (cierre dentro del rango).
- Rompe ORH y reingresa → **venta**. Rompe ORL y reingresa → **compra**.
- El reingreso debe ocurrir dentro de un máximo de velas de confirmación (por defecto 3). Si el precio se queda más tiempo fuera, se considera aceptación del nivel, no barrido, y el setup se descarta.

**3. FVG de ruptura (Fair Value Gap)** — variante 2 (retest). Se opera **a favor** de la ruptura.
- La ruptura deja un FVG de 3 velas: alcista si `mínimo(vela 3) > máximo(vela 1)` con vela central alcista; bajista si `máximo(vela 3) < mínimo(vela 1)` con vela central bajista.
- El precio retrocede y toca el gap (lo rellena).
- Confirmación: una vela en la dirección de la ruptura cierra de nuevo fuera del gap.
- Ruptura de ORH → **compra**. Ruptura de ORL → **venta**.
- Invalidación: si una vela cierra fuera del rango antes de formarse el gap, si una vela cierra atravesando el gap por el lado opuesto, o si se supera el máximo de velas (por defecto 10) para formar el gap o para confirmar.

## 4. Stop loss

- Stop por debajo de ORL (para largos) o por encima de ORH (para cortos).
- Alternativa más ajustada: stop en el punto medio del rango.
- Tamaño de posición: ajustar según distancia al stop, no usar tamaño fijo.

Stop por estructura según el setup:

| Setup | Stop |
|---|---|
| Breakout | Lado opuesto del rango (o punto medio) |
| Liquidity Sweep | Extremo alcanzado durante el barrido (máximo del sweep en ventas, mínimo en compras) |
| FVG | Más allá del origen del FVG: extremo de las velas 1–2 o del retroceso, el que sea más lejano (o punto medio del rango) |

El punto medio no aplica al Liquidity Sweep: la entrada queda dentro del rango y el punto medio estaría del lado del objetivo. Se puede añadir un margen en puntos más allá del stop.

Si el lote calculado por % de riesgo es menor al lote mínimo del símbolo, la operación se descarta: subir al mínimo arriesgaría más que el % configurado.

## 5. Objetivos de ganancia (take profit)

- **Objetivo 1**: proyección del alto del rango (altura ORH-ORL) medida desde el punto de ruptura ("measured move"). Relación riesgo/beneficio típica 2:1 a 3:1.
- **Objetivo 2**: siguiente nivel de soporte/resistencia relevante (máximo/mínimo del día anterior, niveles overnight).
- **Salida por tiempo**: cerrar antes del cierre de sesión (p. ej. 15 minutos antes) para eliminar riesgo de gap overnight — regla crítica, la estrategia es intradía pura.
- Alternativa de trailing stop en días de tendencia fuerte, en vez de objetivo fijo.

### Objetivos en el EA

- **Ratio RR**: TP = entrada ± riesgo × RR (riesgo = distancia entrada–stop). Por defecto 2:1.
- **Measured move**: TP = entrada ± altura del rango × múltiplo.
- **Sin TP**: la salida queda a cargo del cierre de sesión.
- **Cierre parcial (opcional)**: al alcanzar X veces el riesgo (X R, por defecto 1R) se cierra un % del volumen (por defecto 50%) y, opcionalmente, el stop pasa a break even. El resto corre hasta el TP o el cierre de sesión.

## 6. Gestión de riesgo

- Límite de 1-2 operaciones por día por instrumento — evita perseguir ruido en días chopeados.
- Cierre forzado de toda posición antes del cierre de mercado (sin overnight).
- Filtro de volatilidad (ATR) para evitar operar en sesiones de baja actividad.
- Nunca aumentar tamaño tras pérdida (no martingala).

### Horario de operación

- Por defecto en **hora de Nueva York**: búsqueda de entradas de 9:30 a 12:00 ET y cierre forzado a las 15:45 ET. Se puede usar la hora del servidor en su lugar.
- El horario de verano de EE.UU. se aplica automáticamente. El offset GMT del servidor se configura por input (Exness: GMT+0, sin horario de verano). En vivo el EA avisa si no coincide con el servidor real; en el probador no puede verificarlo.
- El límite diario de operaciones se cuenta desde el historial de la cuenta, por lo que se respeta aunque se reinicie el EA.

## 7. Mercados y condiciones donde funciona mejor

- Mejor en mercados líquidos y con tendencia: futuros de índices (ES, NQ) y acciones de alto volumen.
- Funciona peor en mercados laterales o de baja volatilidad (rupturas falsas frecuentes).
- Ventana 9:30–10:00 AM ET (30 min de apertura de NYSE) es la más citada como estándar en acciones/futuros US.

## 8. Tasa de acierto y expectativa

- Win rate típico reportado: 40%–60%, dependiendo de volatilidad, tendencia del mercado y filtros aplicados.
- La rentabilidad depende de mantener ratio riesgo/beneficio favorable (2:1 o más), no de acertar la mayoría de las operaciones.
- Backtests recientes son mixtos: la versión "cruda" (sin filtros) ha perdido efectividad con los años en muchos activos; versiones con filtros de volumen/volatilidad y validación rigurosa muestran mejores resultados.

## 9. Errores comunes / trampas

1. **Sobre-optimización de parámetros** (probar 20+ combinaciones de ventana/stop/target hasta que "algo" salga rentable por azar).
2. Ignorar el régimen de mercado (tendencia vs lateral) — la misma configuración no funciona igual en ambos.
3. No validar con out-of-sample, walk-forward o Monte Carlo antes de operar en real.
4. Tomar todas las señales sin límite diario en días erráticos.
5. Dejar posiciones overnight (rompe la premisa de la estrategia, agrega riesgo de gap).

## 10. Checklist de validación antes de operar en real

- [ ] Backtest fuera de muestra (out-of-sample).
- [ ] Walk-forward analysis (estabilidad en distintos periodos).
- [ ] Simulación Monte Carlo de la curva de resultados.
- [ ] Comparación contra entradas aleatorias (benchmark).
- [ ] Prueba de sensibilidad a pequeñas variaciones de parámetros ("noise test").

## 11. Resumen ejecutivo

| Elemento | Regla |
|---|---|
| Rango | Máx/mín de una vela de la temporalidad de rango (anterior o actual); clásico: primeros 30 min |
| Confirmación | Velas cerradas de una temporalidad menor o igual a la del rango |
| Entrada | Breakout, Liquidity Sweep (fade) o FVG (retest), con filtro de volumen/RSI opcional |
| Stop | Estructura del setup o punto medio del rango |
| Target | RR (2:1 por defecto) o 1–2x altura del rango; cierre parcial y break even opcionales |
| Horario | 9:30–12:00 NY para entradas |
| Salida forzada | 15:45 NY, antes del cierre de sesión, sin overnight |
| Máx. operaciones/día | 1–2 |
| Mercados ideales | Futuros de índices, acciones líquidas, alta volatilidad |

## Fuentes

- [LiteFinance — Opening Range Breakout (ORB) Strategy: Rules, Indicator & Success Rate](https://www.litefinance.org/blog/for-beginners/trading-strategies/opening-range-breakout-strategy/)
- [ForexTester — Opening Range Breakout (ORB) Trading Strategy](https://forextester.com/blog/opening-range-breakout-trading-strategies/)
- [Metrotrade — ORB (Open Range Breakout) Trading Strategy Explained for Futures Traders](https://www.metrotrade.com/orb-open-range-breakout-trading-strategy/)
- [BuildAlpha — Opening Range Breakout Strategy](https://www.buildalpha.com/opening-range-breakout/)
- [QuantifiedStrategies — Opening Range Breakout Strategy (ORB): Backtest](https://www.quantifiedstrategies.com/opening-range-breakout-strategy/)
- [TradeThatSwing — Opening Range Breakout Strategy up 400% This Year](https://tradethatswing.com/opening-range-breakout-strategy-up-400-this-year/)
- [ChartingLens — Opening Range Breakout (ORB) Strategy: The Complete 2026 Day Trading Guide](https://chartinglens.com/blog/opening-range-breakout-strategy)
