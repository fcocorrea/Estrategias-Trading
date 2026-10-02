//+------------------------------------------------------------------+
//|                                        FibonacciPullbackEA.mq5 |
//|  Estrategia de pullback con retrocesos de Fibonacci a favor de   |
//|  una tendencia ya establecida (ver "Descripción estrategia.txt").|
//|                                                                    |
//|  Resumen de la lógica (POO, un componente por responsabilidad):  |
//|   1. CTrendFilter    -> confirma tendencia (precio vs EMA +       |
//|                         estructura de máximos/mínimos).           |
//|   2. CSwingDetector  -> ubica el último impulso (fractales) sobre |
//|                         el que se traza el Fibonacci.             |
//|   3. CFibonacciCalculator -> retroceso 38.2/50/61.8/78.6% y       |
//|                         extensiones 127.2/161.8% + confluencia.   |
//|   4. CConfirmationSignal  -> patrón de velas / cruce EMA / RSI    |
//|                         divergencia (basta una habilitada).       |
//|   5. CSignalFilter   -> capa obligatoria del estándar: volumen >  |
//|                         promedio 20 velas + RSI direccional.      |
//|   6. CRiskManager    -> lotaje por riesgo %, SL bajo/sobre 61.8%, |
//|                         TP1/TP2 por extensión o extremo previo.   |
//|   7. CTradeManager   -> CTrade: apertura, cierre parcial en TP1   |
//|                         y trailing hacia TP2.                     |
//|  Reglas obligatorias del estándar de EAs: volumen, RSI direccio-  |
//|  nal, evaluación solo al cierre de vela y una sola posición       |
//|  abierta a la vez (ver CFibonacciPullbackExpert::OnTick).         |
//+------------------------------------------------------------------+
#property copyright "Pullback Fibonacci EA"
#property version   "1.00"
#property strict

#include "Include\CFibonacciPullbackExpert.mqh"

//======================================================================
// Inputs generales
//======================================================================
input int    InpMagicNumber      = 20260818;  // Magic number
input int    InpSlippage         = 10;        // Slippage en puntos

input double InpRiskPercent      = 1.0;       // Riesgo % del balance por operación (0 = usar lotaje fijo)
input double InpFixedLots        = 0.10;      // Lotaje fijo (si InpRiskPercent <= 0)

//======================================================================
// Filtro de tendencia
//======================================================================
input int    InpTrendEmaPeriod        = 200;   // Período de la EMA de tendencia (ej. 50 u 200)
input bool   InpRequireSwingStructure = true;  // Exigir estructura de máximos/mínimos crecientes o decrecientes

//======================================================================
// Swing / Fibonacci
//======================================================================
input int    InpSwingLookbackBars           = 150;   // Velas hacia atrás para buscar el último impulso
input double InpFibMinRetracement           = 0.382;  // Límite inferior de la zona de entrada
input double InpFibMaxRetracement           = 0.618;  // Límite superior de la zona de entrada (también SL)
input double InpFibExtremeRetracement       = 0.786;  // Retroceso máximo permitido (más allá = descartar)
input bool   InpRequireSRConfluence         = true;   // Exigir confluencia con soporte/resistencia previo
input double InpSRConfluenceTolerancePoints = 150;    // Tolerancia (puntos) para considerar confluencia

//======================================================================
// Confirmación de entrada (basta con que se cumpla una habilitada)
//======================================================================
input bool   InpUseCandlePattern = true;   // Patrón de vela de reversión (envolvente/martillo/pin bar)
input bool   InpUseEmaCross      = true;   // Cruce de EMAs rápidas
input int    InpFastEmaPeriod    = 9;      // Período EMA rápida (cruce de confirmación)
input int    InpSlowEmaPeriod    = 21;     // Período EMA lenta (cruce de confirmación)
input bool   InpUseRsiDivergence = true;   // Divergencia de RSI entre los dos últimos swings

//======================================================================
// Filtro obligatorio del estándar: volumen + RSI direccional
//======================================================================
input int    InpVolumePeriod   = 20;    // Velas para el promedio de volumen
input int    InpRsiPeriod      = 14;    // Período del RSI
input double InpRsiOverbought  = 70.0;  // Nivel de sobrecompra (bloquea compras)
input double InpRsiOversold    = 30.0;  // Nivel de sobreventa (bloquea ventas)

//======================================================================
// Filtro adicional de volumen en el retroceso
//======================================================================
input bool   InpRequireDecreasingPullbackVolume = true; // Exigir volumen decreciente durante el retroceso
input int    InpPullbackVolumeLookback          = 5;    // Velas del retroceso a promediar

//======================================================================
// Entrada
//======================================================================
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_AT_CLOSE; // Al cierre de la vela de confirmación o en su quiebre

//======================================================================
// Riesgo / salidas
//======================================================================
input double           InpSlBufferPoints         = 30;                  // Colchón (puntos) más allá del 61.8%
input ENUM_TP1_METHOD  InpTp1Method              = TP1_EXTENSION_1272;  // Método del primer objetivo
input double           InpFibExtension1          = 1.272;               // Extensión para TP1
input double           InpFibExtension2          = 1.618;               // Extensión para TP2
input double           InpPartialClosePercent    = 50.0;                // % de la posición a cerrar en TP1
input bool             InpUseTrailingAfterPartial = true;                // Trailing en el remanente tras TP1
input double           InpTrailingPoints          = 300;                 // Distancia (puntos) del trailing stop

CFibonacciPullbackExpert g_ea;

//+------------------------------------------------------------------+
int OnInit(void)
  {
   SFibExpertParams p;

   p.magic    = InpMagicNumber;
   p.slippage = InpSlippage;

   p.riskPercent = InpRiskPercent;
   p.fixedLots   = InpFixedLots;

   p.trendEmaPeriod        = InpTrendEmaPeriod;
   p.requireSwingStructure = InpRequireSwingStructure;

   p.swingLookbackBars           = InpSwingLookbackBars;
   p.fibMinRetracement           = InpFibMinRetracement;
   p.fibMaxRetracement           = InpFibMaxRetracement;
   p.fibExtremeRetracement       = InpFibExtremeRetracement;
   p.requireSrConfluence         = InpRequireSRConfluence;
   p.srConfluenceTolerancePoints = InpSRConfluenceTolerancePoints;

   p.useCandlePattern = InpUseCandlePattern;
   p.useEmaCross       = InpUseEmaCross;
   p.fastEmaPeriod     = InpFastEmaPeriod;
   p.slowEmaPeriod     = InpSlowEmaPeriod;
   p.useRsiDivergence  = InpUseRsiDivergence;

   p.volumePeriod  = InpVolumePeriod;
   p.rsiPeriod     = InpRsiPeriod;
   p.rsiOverbought = InpRsiOverbought;
   p.rsiOversold   = InpRsiOversold;

   p.requireDecreasingPullbackVolume = InpRequireDecreasingPullbackVolume;
   p.pullbackVolumeLookback          = InpPullbackVolumeLookback;

   p.entryMode = InpEntryMode;

   p.slBufferPoints         = InpSlBufferPoints;
   p.tp1Method               = InpTp1Method;
   p.fibExtension1            = InpFibExtension1;
   p.fibExtension2            = InpFibExtension2;
   p.partialClosePercent      = InpPartialClosePercent;
   p.useTrailingAfterPartial  = InpUseTrailingAfterPartial;
   p.trailingPoints           = InpTrailingPoints;

   if(!g_ea.Init(p))
     {
      Print("Error inicializando Fibonacci Pullback EA");
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_ea.Deinit();
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   g_ea.OnTick();
  }
//+------------------------------------------------------------------+
