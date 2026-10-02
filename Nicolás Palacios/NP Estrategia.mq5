//+------------------------------------------------------------------+
//|                                         SR_MTF_EA_Standalone.mq5 |
//|                                                                  |
//|  EA de Soportes y Resistencias Multi-Temporalidad (M5..D1).      |
//|                                                                  |
//|  VERSION DE ARCHIVO UNICO: contiene todos los modulos en linea,  |
//|  sin carpeta Include. Originalmente generado por                 |
//|  build_standalone.sh desde Experts/SRMTF/, pero esa version      |
//|  modular no se conserva: ESTE archivo es ahora la fuente.        |
//|                                                                  |
//|  Detecta zonas de concentracion de maximos/minimos por KDE,      |
//|  ajusta cada zona por minimos cuadrados ponderados (penalizados  |
//|  por distancia al precio actual), pondera por temporalidad y     |
//|  opera el rechazo confirmado del nivel (volumen + RSI).          |
//|  Ver PLAN.md para el detalle matematico completo.                |
//|                                                                  |
//|  Unica dependencia externa: Trade\Trade.mqh, que forma parte de  |
//|  la libreria estandar de MetaTrader 5 (siempre presente).        |
//+------------------------------------------------------------------+
#property copyright "SRMTF"
#property version   "1.10"

#include <Trade\Trade.mqh>


//==================================================================+
//| SECCION 1/17 - Tipos: enums y structs compartidos
//==================================================================+

//+------------------------------------------------------------------+
//|                                                       Types.mqh |
//|  Enums y structs compartidos por todo el EA SRMTF               |
//+------------------------------------------------------------------+

//--- Modo de lotaje
enum ENUM_LOT_MODE
  {
   LOT_MODE_FIXED,          // Lotaje fijo
   LOT_MODE_RISK_PERCENT    // % de riesgo sobre el balance
  };

//--- Dirección de operativa permitida
enum ENUM_TRADE_DIRECTION
  {
   DIR_BUY_ONLY,            // Solo compras (soportes)
   DIR_SELL_ONLY,           // Solo ventas (resistencias)
   DIR_BOTH,                // Ambas direcciones
   DIR_TREND_FOLLOW         // Según pendiente de EMA 200
  };

//--- Origen del precio del SL estructural
enum ENUM_STRUCT_SL_MODE
  {
   STRUCT_SL_MANUAL,        // Precio fijado por el usuario
   STRUCT_SL_AUTO           // Calculado por el modelo de probabilidad de toque
  };

//--- Un punto de precio (máximo o mínimo de una vela) usado en el clustering
struct SPricePoint
  {
   double   price;          // High o Low de la vela
   int      barShift;       // antigüedad en velas de su TF (1 = última cerrada)
   bool     isHigh;         // true = máximo, false = mínimo
   double   weight;         // wj: peso por distancia al precio actual (paso 4)
  };

//--- Zona de concentración detectada en UNA temporalidad, antes del ajuste WLS
struct SLevelZone
  {
   ENUM_TIMEFRAMES  timeframe;
   double           center;        // centro de densidad (semilla del cluster, del KDE)
   int              pointIdx[];    // índices dentro del array de puntos de esa TF
   double           atrRef;        // ATR de esa TF (última vela cerrada)
   int              distinctBars;  // velas DISTINTAS que aportaron algún punto a la zona
  };

//--- Nivel ya ajustado, puntuado y listo para fusión/selección
struct SLevel
  {
   double           price;         // L*: resultado del ajuste por mínimos cuadrados ponderados
   double           sigma;         // dispersión residual ponderada, en precio
   double           sigmaAtr;      // sigma normalizada por ATR de esa TF (adimensional)
   double           effTouches;    // N_eff: suma de pesos de los puntos de la zona (uso interno del puntaje)
   int              touchCandles;  // conteo de velas DISTINTAS que tocaron la zona (para mostrar al usuario)
   double           scoreRaw;      // puntaje antes de escalar por temporalidad
   double           score;         // puntaje final tras escalar por TF (menor = mejor)
   ENUM_TIMEFRAMES  timeframe;     // TF de origen (antes de fusionar)
   int              tfMask;        // bitmask de TFs fusionadas (confluencia)
   int              confluence;    // cuántas TFs distintas aportaron al nivel fusionado
   bool             isResistance;  // true = por sobre el precio actual (línea de venta)
  };

//--- Bits del abanico de temporalidades, usados en SLevel.tfMask
#define SRMTF_BIT_M5   1
#define SRMTF_BIT_M15  2
#define SRMTF_BIT_M30  4
#define SRMTF_BIT_H1   8
#define SRMTF_BIT_H4   16
#define SRMTF_BIT_D1   32

//+------------------------------------------------------------------+
//| Mapea una ENUM_TIMEFRAMES del abanico fijo a su bit correspondiente|
//+------------------------------------------------------------------+
int TimeframeToBit(ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M5:  return SRMTF_BIT_M5;
      case PERIOD_M15: return SRMTF_BIT_M15;
      case PERIOD_M30: return SRMTF_BIT_M30;
      case PERIOD_H1:  return SRMTF_BIT_H1;
      case PERIOD_H4:  return SRMTF_BIT_H4;
      case PERIOD_D1:  return SRMTF_BIT_D1;
      default:         return 0;
     }
  }

//+------------------------------------------------------------------+
//| Nombre corto de una temporalidad, para logs y etiquetas en el   |
//| gráfico (StringSubstr sobre EnumToString sería frágil ante      |
//| cambios de nombre del enum nativo).                              |
//+------------------------------------------------------------------+
string TimeframeShortName(ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return EnumToString(tf);
     }
  }

//+------------------------------------------------------------------+
//| Arma la etiqueta de confluencia ("M15+H1+H4") a partir del mask |
//+------------------------------------------------------------------+
string TfMaskToLabel(int mask)
  {
   string label = "";
   if((mask & SRMTF_BIT_M5)  != 0) label += (label == "" ? "" : "+") + "M5";
   if((mask & SRMTF_BIT_M15) != 0) label += (label == "" ? "" : "+") + "M15";
   if((mask & SRMTF_BIT_M30) != 0) label += (label == "" ? "" : "+") + "M30";
   if((mask & SRMTF_BIT_H1)  != 0) label += (label == "" ? "" : "+") + "H1";
   if((mask & SRMTF_BIT_H4)  != 0) label += (label == "" ? "" : "+") + "H4";
   if((mask & SRMTF_BIT_D1)  != 0) label += (label == "" ? "" : "+") + "D1";
   return label;
  }
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 2/17 - Inputs del EA
//==================================================================+

input group "General"
input long   InpMagicNumber       = 555111;          // Magic number
input int    InpSlippage          = 10;              // Slippage en puntos
input ENUM_TIMEFRAMES InpBaseTimeframe = PERIOD_CURRENT; // Temporalidad base (PERIOD_CURRENT = la del gráfico)
input bool   InpVerboseLog        = true;            // Log detallado de niveles seleccionados en cada recálculo
input bool   InpRequireConfirmation = false;           // Exigir confirmación de volumen y cierre de vela antes de operar (false = operar en el instante del toque)
input int    InpMaxOpenPositions  = 50;                // Máximo de posiciones abiertas simultáneas (mismo símbolo+magic; >1 requiere cuenta de cobertura)
input double InpMinEntryDistanceAtr = 1.0;            // Distancia mínima entre una entrada nueva y cualquier posición propia ya abierta (x ATR base; 0 = sin mínimo)
input double InpMaxSpreadAtr      = 0.5;               // Spread máximo permitido para abrir (x ATR base; 0 = sin filtro)

input group "Detección de Niveles"
input int    InpBarsToAnalyze     = 500;              // N velas a analizar por temporalidad
input int    InpMinTouches        = 3;                // Mínimo de toques (velas distintas) para que una zona sea válida

input group "Clustering (KDE)"
input double InpKdeBandwidthAtr   = 0.5;              // Ancho de banda del kernel (x ATR de esa TF)
input int    InpKdeGridNodes      = 400;              // Nodos mínimos de la grilla de densidad (se amplía si el paso supera 1/4 del ancho de banda)
input double InpMinDensityRatio   = 0.25;             // Densidad mínima relativa al pico, para aceptar un máximo local
input double InpZoneWidthAtr      = 0.5;              // Ancho de pertenencia a la zona (x ATR de esa TF)

input group "Puntaje"
input double InpRelevanceRangeAtr = 20.0;             // D_max: rango de relevancia por distancia al precio (x ATR de esa TF)
input double InpMinWeight         = 0.05;             // Piso del peso lineal por distancia (wj)
input double InpDistPenaltyLambda = 0.15;             // λ: penalización del puntaje por distancia del nivel al precio (x ATR base)
input double InpTouchExponent     = 1.0;              // β: exponente del divisor por toques efectivos (N_eff^β)
input double InpMinSigmaAtr       = 0.02;             // Piso de sigma normalizada (evita colapso a score≈0)
input double InpTimeDecayHalfLife = 200.0;            // Vida media del peso por antigüedad, en velas de cada TF (0 = sin decaimiento)

input group "Multi-Temporalidad"
input double InpTfExponent        = 0.5;              // γ: exponente del divisor por ratio de temporalidad (ver PLAN.md §3.6)
input double InpMergeToleranceAtr = 0.5;              // Tolerancia de fusión entre niveles cercanos (x ATR base)
input double InpConfluenceBonus   = 0.25;             // Bonus de puntaje por cada TF adicional en confluencia

input group "Selección de Líneas"
input int    InpMaxLinesAbove       = 0;                // Máximo de líneas de venta (resistencias) sobre el precio
input int    InpMaxLinesBelow       = 10;                // Máximo de líneas de compra (soportes) bajo el precio
input double InpMinSeparationAtr    = 1.0;           // Separación mínima entre líneas del mismo lado (x ATR base)

input group "Señal"
input ENUM_TRADE_DIRECTION InpTradeDirection = DIR_BUY_ONLY; // Dirección de operativa permitida
input double InpTouchToleranceAtr = 0.1;               // Tolerancia mínima de toque del nivel (x ATR base; se afina por sigma de cada nivel)
input int    InpLevelCooldownBars = 1;                 // Velas base de espera antes de volver a operar un mismo nivel (0 = sin espera)

input group "Filtro de Tendencia"
input ENUM_TIMEFRAMES InpTrendTimeframe = PERIOD_CURRENT; // Temporalidad de la EMA de tendencia (PERIOD_CURRENT = la base)
input int    InpTrendEmaPeriod    = 200;               // Período de la EMA de tendencia
input int    InpTrendSlopeBars    = 5;                 // Velas hacia atrás para medir la pendiente
input double InpTrendThresholdAtr = 0.0;               // Umbral mínimo de pendiente para considerar tendencia (x ATR)

input group "Filtro de Volumen"
input int    InpVolumePeriod      = 20;                // Velas para el promedio de volumen
input bool   InpUseRealVolume     = true;               // Usar volumen real si el símbolo lo provee (fallback a tick volume)

input group "Filtro RSI"
input bool   InpUseRsiFilter      = true;               // Activar filtro RSI direccional (no es parte de la estrategia original)
input int    InpRsiPeriod         = 14;                 // Período del RSI
input double InpRsiOverbought     = 70.0;                // Nivel de sobrecompra
input double InpRsiOversold       = 30.0;                // Nivel de sobreventa

input group "ATR"
input int    InpAtrPeriod         = 14;                 // Período ATR (usado en todas las temporalidades)

input group "Stop Loss / Take Profit"
input bool   InpUseStopLoss       = false;                // Activar stop loss
input double InpSlAtrMultiplier   = 2.0;                 // SL = ATR x este múltiplo
input bool   InpUseTakeProfit     = false;                // Activar take profit
input double InpTpAtrMultiplier   = 4.0;                 // TP = ATR x este múltiplo

input group "Stop Loss Estructural"
input bool   InpUseStructuralSL   = true;                // Activar SL estructural (reemplaza al SL de arriba; solo compra)
input ENUM_STRUCT_SL_MODE InpStructuralSLMode = STRUCT_SL_MANUAL; // Modo: precio manual o calculado por el modelo
input double InpStructuralSLPrice = 30000.0;                  // Precio absoluto del SL estructural (modo manual)
input ENUM_TIMEFRAMES InpStructSlTimeframe = PERIOD_W1;       // Modelo: temporalidad de análisis (W1 o MN1)
input int    InpStructSlLookbackBars  = 520;                  // Modelo: velas de historia a analizar (usa las disponibles hasta este tope)
input int    InpStructSlHorizonBars   = 52;                   // Modelo: horizonte H en velas durante el cual el SL no debería tocarse
input double InpStructSlMaxTouchProb  = 5.0;                  // Modelo: α, probabilidad máxima (%) de tocar el SL dentro de H (5% en 52 semanas ≈ 1 vez cada 20 años)
input double InpStructSlDriftWeight   = 0.5;                  // Modelo: κ, crédito a la deriva alcista histórica (0 = ninguno, 1 = completo)
input int    InpStructSlRecentVolBars = 26;                   // Modelo: velas de la volatilidad reciente (se usa la mayor entre reciente e histórica)

input group "Take Profit Estructural"
input bool   InpUseStructuralTP   = false;                // Activar TP estructural (reemplaza al TP de arriba; TP = resistencia más cercana en compra / soporte más cercano en venta)

input group "Break Even"
input bool   InpUseBreakEven           = false;            // Activar break even
input double InpBreakEvenTriggerAtrMul = 1.5;              // Trigger = ATR x este múltiplo
input double InpBreakEvenOffsetAtrMul  = 0.2;               // Offset asegurado = ATR x este múltiplo

input group "Trailing Stop"
input bool   InpUseTrailingStop           = true;              // Activar trailing stop
input double InpTrailingTriggerAtrMultiplier = 2.0;            // Inicio del trailing = ATR x este múltiplo
input double InpTrailingAtrMultiplier     = 2.0;                // Distancia mantenida = ATR x este múltiplo
input double InpTrailingStepAtrMultiplier = 0.1;                // Paso mínimo para volver a mover el SL = ATR x este múltiplo

input group "Lotaje"
input ENUM_LOT_MODE InpLotMode    = LOT_MODE_RISK_PERCENT;         // Modo de cálculo del lotaje
input double InpFixedLots         = 0.10;                    // Lotaje fijo (modo LOT_MODE_FIXED)
input double InpRiskPercent       = 5.0;                     // % de capital a arriesgar por operación (modo LOT_MODE_RISK_PERCENT; capital = mín(balance, equity))
input double InpMaxTotalRiskPercent = 10.0;                  // % de capital máximo en riesgo sumando todas las posiciones propias (0 = sin tope)

input group "Optimización"
input int    InpTesterMinTrades   = 30;                      // Operaciones mínimas para que OnTester puntúe una pasada (menos = 0)

input group "Visualización"
input bool   InpDrawLevels        = true;                     // Dibujar las líneas de niveles seleccionadas
input color  InpColorSupport      = clrLimeGreen;               // Color de las líneas de soporte (compra)
input color  InpColorResistance   = clrTomato;                  // Color de las líneas de resistencia (venta)


//==================================================================+
//| SECCION 3/17 - Utilidades de simbolo (tick, stops level, filling, posicion propia)
//==================================================================+

//+------------------------------------------------------------------+
//|                                                   SymbolUtils.mqh |
//|  Utilidades de símbolo/cuenta compartidas: normalización de       |
//|  precios al tick del instrumento, distancia mínima de stops del  |
//|  bróker, modo de llenado soportado y selección de la posición    |
//|  propia (symbol + magic).                                         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Redondea un precio al múltiplo de SYMBOL_TRADE_TICK_SIZE más      |
//| cercano. CTrade NO normaliza: enviar un SL/TP derivado de ATR sin |
//| redondear provoca TRADE_RETCODE_INVALID_STOPS (10016) en          |
//| instrumentos cuyo tick no es potencia de 10 (índices, futuros).   |
//+------------------------------------------------------------------+
double NormalizePriceToTick(double price)
  {
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);

   return NormalizeDouble(MathRound(price / tickSize) * tickSize, digits);
  }

//+------------------------------------------------------------------+
//| Distancia de congelamiento (en precio): si el SL/TP VIGENTE de una|
//| posición está a menos de esto del precio, el servidor rechaza    |
//| cualquier modificación (retcode 10029).                          |
//+------------------------------------------------------------------+
double GetFreezeDistance(void)
  {
   long   freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double point             = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (double)freezeLevelPoints * point;
  }

//+------------------------------------------------------------------+
//| Distancia mínima (en precio) que el bróker exige entre el precio |
//| de mercado y un SL/TP nuevo. Se toma el mayor entre stops level y |
//| freeze level: un stop nuevo dentro de la zona congelada tampoco   |
//| podría modificarse después. 0 = sin restricción declarada.        |
//+------------------------------------------------------------------+
double GetMinStopDistance(void)
  {
   long   stopsLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point            = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return MathMax((double)stopsLevelPoints * point, GetFreezeDistance());
  }

//+------------------------------------------------------------------+
//| Precio contra el que el servidor valida SL/TP: Bid para compras,  |
//| Ask para ventas (el lado al que se CIERRA la posición, no el lado |
//| al que se abre).                                                  |
//+------------------------------------------------------------------+
double GetStopReferencePrice(bool isBuy)
  {
   return isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  }

//+------------------------------------------------------------------+
//| Verifica que un SL/TP respete la distancia mínima del bróker.     |
//| 'isBuy' = tipo de posición; 'isStopLoss' define de qué lado del   |
//| precio de referencia debe quedar el nivel. 'refPrice' debe venir  |
//| de GetStopReferencePrice().                                       |
//+------------------------------------------------------------------+
bool IsStopDistanceValid(bool isBuy, bool isStopLoss, double refPrice, double stopPrice)
  {
   if(stopPrice <= 0.0)
      return true; // sin stop definido: nada que validar

   double minDistance = GetMinStopDistance();
   if(minDistance <= 0.0)
      return true;

   //--- SL de compra y TP de venta van por debajo del precio; los otros dos por encima
   bool mustBeBelow = (isBuy == isStopLoss);

   if(mustBeBelow)
      return (refPrice - stopPrice) >= minDistance;

   return (stopPrice - refPrice) >= minDistance;
  }

//+------------------------------------------------------------------+
//| Modo de llenado realmente soportado por el símbolo. Fijar         |
//| ORDER_FILLING_FOK a ciegas hace que todas las órdenes se rechacen |
//| con retcode 10030 en instrumentos que solo admiten IOC o Return.  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING SelectFillingMode(void)
  {
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Selecciona la posición de índice 'index' y devuelve su ticket     |
//| solo si es propia (símbolo actual + magic); 0 en otro caso.       |
//| PositionSelect(_Symbol) no sirve en cuentas de cobertura: puede   |
//| seleccionar la posición de otro EA o una manual. Punto único de   |
//| filtrado para todo recorrido de posiciones propias del EA.        |
//+------------------------------------------------------------------+
ulong SelectOwnPosition(int index, long magicNumber)
  {
   ulong ticket = PositionGetTicket(index); // selecciona la posición al obtener el ticket
   if(ticket == 0)
      return 0;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return 0;
   if(PositionGetInteger(POSITION_MAGIC) != magicNumber)
      return 0;
   return ticket;
  }

//+------------------------------------------------------------------+
//| Cuenta las posiciones propias (símbolo actual + magic) abiertas,  |
//| para el gate de entradas (InpMaxOpenPositions).                   |
//+------------------------------------------------------------------+
int CountOwnPositions(long magicNumber)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectOwnPosition(i, magicNumber) != 0)
         count++;
   return count;
  }

//+------------------------------------------------------------------+
//| Capital sobre el que se mide el riesgo: el menor entre balance y  |
//| equity. El balance solo no ve las pérdidas flotantes de las       |
//| posiciones abiertas y sobredimensiona cada entrada nueva.         |
//+------------------------------------------------------------------+
double GetRiskCapital(void)
  {
   return MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
  }

//+------------------------------------------------------------------+
//| Pérdida monetaria de 'volume' lotes si el precio va de 'fromPrice'|
//| a 'stopPrice'. OrderCalcProfit convierte a la moneda de la cuenta |
//| con el tipo de cambio del lado perdedor; TICK_VALUE (lado        |
//| ganador) la subestima en símbolos con otra moneda de cotización.  |
//| Devuelve 0 si el stop queda del lado de la ganancia.              |
//+------------------------------------------------------------------+
bool CalcStopLossMoney(bool isBuy, double volume, double fromPrice, double stopPrice, double &lossOut)
  {
   lossOut = 0.0;
   ENUM_ORDER_TYPE type   = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double          profit = 0.0;

   if(OrderCalcProfit(type, _Symbol, volume, fromPrice, stopPrice, profit))
     {
      lossOut = MathMax(0.0, -profit);
      return true;
     }

   double tickValueLoss = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double tickSize      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValueLoss <= 0.0 || tickSize <= 0.0)
     {
      Print(__FUNCTION__, ": OrderCalcProfit falló (code=", GetLastError(),
            ") y no hay tick value/size de respaldo");
      return false;
     }

   double adverseMove = isBuy ? (fromPrice - stopPrice) : (stopPrice - fromPrice);
   lossOut = MathMax(0.0, adverseMove / tickSize * tickValueLoss * volume);
   return true;
  }

//+------------------------------------------------------------------+
//| Riesgo monetario vivo de todas las posiciones propias: lo que se  |
//| perdería desde el precio actual si todos los SL se ejecutaran.    |
//| Se mide desde el precio actual (no desde la apertura) porque el   |
//| capital de referencia ya incluye la pérdida flotante vía equity.  |
//| Devuelve false si alguna posición propia no tiene SL: su riesgo   |
//| no es acotable y el tope total no puede garantizarse.             |
//+------------------------------------------------------------------+
bool GetOpenRiskMoney(long magicNumber, double &riskOut)
  {
   riskOut = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(SelectOwnPosition(i, magicNumber) == 0)
         continue;

      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
         return false;

      bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double loss;
      if(!CalcStopLossMoney(isBuy, volume, GetStopReferencePrice(isBuy), sl, loss))
         return false;
      riskOut += loss;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Trading automático habilitado en terminal, programa y cuenta.     |
//| Sin esto, cada tick generaría un envío o PositionModify fallido.  |
//+------------------------------------------------------------------+
bool IsAutoTradingAllowed(void)
  {
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0
          && MQLInfoInteger(MQL_TRADE_ALLOWED) != 0
          && AccountInfoInteger(ACCOUNT_TRADE_EXPERT) != 0
          && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) != 0;
  }

//+------------------------------------------------------------------+
//| El símbolo admite abrir una posición nueva en esa dirección       |
//| (mercado cerrado, solo-cierre, solo-largos o solo-cortos).        |
//+------------------------------------------------------------------+
bool IsSymbolOpenAllowed(bool isBuy)
  {
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   switch(mode)
     {
      case SYMBOL_TRADE_MODE_FULL:      return true;
      case SYMBOL_TRADE_MODE_LONGONLY:  return isBuy;
      case SYMBOL_TRADE_MODE_SHORTONLY: return !isBuy;
      default:                          return false; // DISABLED o CLOSEONLY
     }
  }
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 4/17 - CBarMonitor: deteccion de vela nueva
//==================================================================+

//+------------------------------------------------------------------+
//|                                                  BarMonitor.mqh |
//|  CBarMonitor: detecta el cierre de una vela nueva en una TF dada|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CBarMonitor: instanciable una vez por temporalidad a monitorear.|
//| Usada tanto para la TF base (gate de señal) como para cada TF   |
//| del abanico (gate de recálculo de zonas, ver LevelRepository).  |
//+------------------------------------------------------------------+
class CBarMonitor
  {
private:
   ENUM_TIMEFRAMES   m_timeframe;
   datetime          m_lastBarTime;

public:
                     CBarMonitor(void) : m_timeframe(PERIOD_CURRENT), m_lastBarTime(0) {}

   void              Init(ENUM_TIMEFRAMES timeframe)
     {
      m_timeframe   = timeframe;
      m_lastBarTime = 0;
     }

   //--- true una única vez por vela nueva cerrada de m_timeframe
   bool              IsNewBar(void)
     {
      datetime currentBarTime = iTime(_Symbol, m_timeframe, 0);
      if(currentBarTime == 0)
         return false; // historial aún no disponible para esta TF

      if(currentBarTime == m_lastBarTime)
         return false;

      m_lastBarTime = currentBarTime;
      return true;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 5/17 - CAtrProvider: handles de ATR por temporalidad
//==================================================================+

//+------------------------------------------------------------------+
//|                                                 AtrProvider.mqh |
//|  CAtrProvider: un handle de ATR por temporalidad, creado una    |
//|  sola vez en OnInit y liberado en OnDeinit (regla del estándar).|
//+------------------------------------------------------------------+

//--- Peor caso: 7 temporalidades del repositorio (abanico + base fuera del abanico)
//--- + la TF del filtro de tendencia si difiere de todas ellas. Se deja margen.
#define SRMTF_MAX_ATR_HANDLES 10

//+------------------------------------------------------------------+
//| CAtrProvider: registra handles de iATR bajo demanda (Register), |
//| todos creados antes de operar, y expone el valor por TF+shift.  |
//+------------------------------------------------------------------+
class CAtrProvider
  {
private:
   ENUM_TIMEFRAMES   m_timeframes[SRMTF_MAX_ATR_HANDLES];
   int               m_handles[SRMTF_MAX_ATR_HANDLES];
   int               m_count;
   int               m_period;

   int               FindSlot(ENUM_TIMEFRAMES tf)
     {
      for(int i = 0; i < m_count; i++)
         if(m_timeframes[i] == tf)
            return i;
      return -1;
     }

public:
                     CAtrProvider(void) : m_count(0), m_period(14) {}

   void              SetPeriod(int period) { m_period = period; }

   //--- Crea (si no existe) el handle de ATR para 'tf'. Llamar solo desde OnInit.
   bool              Register(ENUM_TIMEFRAMES tf)
     {
      if(FindSlot(tf) >= 0)
         return true;

      if(m_count >= SRMTF_MAX_ATR_HANDLES)
        {
         Print(__FUNCTION__, ": excedido el máximo de handles ATR (", SRMTF_MAX_ATR_HANDLES, ")");
         return false;
        }

      int handle = iATR(_Symbol, tf, m_period);
      if(handle == INVALID_HANDLE)
        {
         Print(__FUNCTION__, ": no se pudo crear el handle de ATR para ", EnumToString(tf),
               ", code=", GetLastError());
         return false;
        }

      m_timeframes[m_count] = tf;
      m_handles[m_count]    = handle;
      m_count++;
      return true;
     }

   void              Deinit(void)
     {
      for(int i = 0; i < m_count; i++)
         if(m_handles[i] != INVALID_HANDLE)
            IndicatorRelease(m_handles[i]);
      m_count = 0;
     }

   //--- Valor de ATR en la vela shift (0 = vela en formación, 1 = última cerrada)
   bool              GetValue(ENUM_TIMEFRAMES tf, int shift, double &out)
     {
      int slot = FindSlot(tf);
      if(slot < 0)
        {
         Print(__FUNCTION__, ": TF ", EnumToString(tf), " no registrada");
         return false;
        }

      double buffer[];
      ArraySetAsSeries(buffer, true);

      if(CopyBuffer(m_handles[slot], 0, shift, 1, buffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando ATR de ", EnumToString(tf), ", code=", GetLastError());
         return false;
        }

      out = buffer[0];
      return (out > 0.0);
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 6/17 - CPointCollector (paso 1): maximos y minimos
//==================================================================+

//+------------------------------------------------------------------+
//|                                              PointCollector.mqh |
//|  CPointCollector: paso 1 — extrae los 2N máximos y mínimos de   |
//|  las últimas N velas cerradas de una temporalidad.               |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| CPointCollector: sin estado entre llamadas; LevelRepository es  |
//| quien decide cuándo volver a invocarla (gate por vela nueva de  |
//| cada TF, ver §4 del plan).                                       |
//+------------------------------------------------------------------+
class CPointCollector
  {
private:
   int               m_barsToAnalyze;

public:
                     CPointCollector(void) : m_barsToAnalyze(300) {}

   void              SetBarsToAnalyze(int n) { m_barsToAnalyze = n; }

   //--- true si hay suficiente historial descargado en 'tf' para analizar N velas
   bool              IsReady(ENUM_TIMEFRAMES tf)
     {
      return Bars(_Symbol, tf) >= (m_barsToAnalyze + 2);
     }

   //--- Llena 'points' con los 2N puntos (High/Low) de las N velas cerradas [1..N] de 'tf'.
   //--- Devuelve false si el historial no está disponible (llamar antes IsReady()).
   bool              Collect(ENUM_TIMEFRAMES tf, SPricePoint &points[])
     {
      if(!IsReady(tf))
         return false;

      MqlRates rates[];
      ArraySetAsSeries(rates, true);

      int copied = CopyRates(_Symbol, tf, 1, m_barsToAnalyze, rates);
      if(copied <= 0)
        {
         Print(__FUNCTION__, ": error copiando rates de ", EnumToString(tf), ", code=", GetLastError());
         return false;
        }

      ArrayResize(points, copied * 2);

      for(int i = 0; i < copied; i++)
        {
         int highIdx = i * 2;
         int lowIdx  = i * 2 + 1;

         points[highIdx].price    = rates[i].high;
         points[highIdx].barShift = i + 1; // shift real respecto a la vela en formación
         points[highIdx].isHigh   = true;
         points[highIdx].weight   = 1.0;   // se recalcula en LevelFitter (paso 4)

         points[lowIdx].price    = rates[i].low;
         points[lowIdx].barShift = i + 1;
         points[lowIdx].isHigh   = false;
         points[lowIdx].weight   = 1.0;
        }

      return true;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 7/17 - CZoneFinder (paso 2): clustering por KDE
//==================================================================+

//+------------------------------------------------------------------+
//|                                                   ZoneFinder.mqh |
//|  CZoneFinder: paso 2 — detecta zonas de concentración de puntos |
//|  mediante estimación de densidad por kernel (KDE, Epanechnikov).|
//+------------------------------------------------------------------+


//--- Techo de nodos de la grilla KDE: acota el costo por TF cuando el rango de precio
//--- es muy amplio respecto del ancho de banda (p.ej. D1 con ATR bajo).
#define SRMTF_KDE_MAX_NODES 20000

//+------------------------------------------------------------------+
//| CZoneFinder: sin estado entre llamadas. Toda la configuración se|
//| pasa por parámetro para que LevelRepository controle los inputs.|
//+------------------------------------------------------------------+
class CZoneFinder
  {
private:
   //--- Kernel de Epanechnikov: K(u) = 0.75(1-u^2) para |u|<=1, 0 fuera. Soporte compacto.
   double            Kernel(double u)
     {
      if(u <= -1.0 || u >= 1.0)
         return 0.0;
      return 0.75 * (1.0 - u * u);
     }

   //--- Ordena los índices de 'points' por precio ascendente (insertion sort;
   //--- M típicamente < 1000, suficiente y sin dependencias externas).
   void              SortIndicesByPrice(const SPricePoint &points[], int &order[])
     {
      int n = ArraySize(points);
      ArrayResize(order, n);
      for(int i = 0; i < n; i++)
         order[i] = i;

      for(int i = 1; i < n; i++)
        {
         int   key   = order[i];
         double keyP = points[key].price;
         int j = i - 1;
         while(j >= 0 && points[order[j]].price > keyP)
           {
            order[j + 1] = order[j];
            j--;
           }
         order[j + 1] = key;
        }
     }

public:
   //--- Detecta zonas de concentración en 'points' (todas de la misma TF).
   //--- 'atrRef' = ATR de esa TF. Los parámetros vienen de los inputs "Clustering (KDE)".
   //--- Devuelve las zonas encontradas en 'zonesOut' (sin ajustar todavía: solo membresía).
   bool              FindZones(const SPricePoint &points[],
                                ENUM_TIMEFRAMES timeframe,
                                double atrRef,
                                double bandwidthAtrMul,
                                double zoneWidthAtrMul,
                                double minDensityRatio,
                                int    gridNodesMin,
                                int    minTouches,
                                SLevelZone &zonesOut[])
     {
      int m = ArraySize(points);
      ArrayResize(zonesOut, 0);

      if(m == 0 || atrRef <= 0.0)
         return false;

      double h = bandwidthAtrMul * atrRef;
      if(h <= 0.0)
         return false;

      //--- Orden ascendente por precio: permite ventana deslizante O(G+M) en vez de O(G*M)
      int order[];
      SortIndicesByPrice(points, order);

      double priceMin = points[order[0]].price;
      double priceMax = points[order[m - 1]].price;
      if(priceMax <= priceMin)
         return false; // todos los puntos al mismo precio: no hay dispersión que analizar

      //--- El paso de la grilla debe ser <= h/4: con soporte compacto (Epanechnikov), un
      //--- paso mayor que el ancho de banda deja picos de densidad entre nodos sin
      //--- evaluar, y en TFs altas (rango de precio amplio) se perdían zonas enteras.
      //--- 'gridNodesMin' es solo el piso; se amplía lo necesario, sin bajar del tick
      //--- del símbolo (no hay resolución real por debajo) y con un techo de cómputo.
      double range      = priceMax - priceMin;
      int    nodesByBw  = (int)MathCeil(range / (h / 4.0)) + 1;
      double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      int    maxByTick  = (tickSize > 0.0) ? (int)MathFloor(range / tickSize) + 1 : SRMTF_KDE_MAX_NODES;
      int    gridNodes  = MathMax(gridNodesMin, nodesByBw);
      gridNodes = MathMin(gridNodes, MathMin(maxByTick, SRMTF_KDE_MAX_NODES));
      gridNodes = MathMax(2, gridNodes);

      double step = (priceMax - priceMin) / (gridNodes - 1);

      double density[];
      ArrayResize(density, gridNodes);

      //--- Ventana deslizante [lo, hi) de puntos con precio en [x-h, x+h]
      int lo = 0, hi = 0;
      double maxDensity = 0.0;

      for(int g = 0; g < gridNodes; g++)
        {
         double x = priceMin + g * step;

         while(lo < m && points[order[lo]].price < x - h)
            lo++;
         while(hi < m && points[order[hi]].price <= x + h)
            hi++;

         double f = 0.0;
         for(int k = lo; k < hi; k++)
            f += Kernel((x - points[order[k]].price) / h);

         density[g] = f;
         if(f > maxDensity)
            maxDensity = f;
        }

      if(maxDensity <= 0.0)
         return false;

      double densityFloor = minDensityRatio * maxDensity;

      //--- Máximos locales de la densidad por sobre el piso relativo
      double centers[];
      int    centerCount = 0;
      ArrayResize(centers, gridNodes);

      for(int g = 1; g < gridNodes - 1; g++)
        {
         if(density[g] >= densityFloor && density[g] >= density[g - 1] && density[g] >= density[g + 1])
           {
            //--- evita registrar mesetas planas como múltiples máximos contiguos. Con la
            //--- grilla fina (paso <= h/4) una meseta abarca varios nodos, así que el umbral
            //--- se mide en ancho de banda y no en pasos de grilla.
            if(centerCount > 0 && MathAbs(centers[centerCount - 1] - (priceMin + g * step)) < MathMax(step * 2.0, h * 0.5))
               continue;
            centers[centerCount] = priceMin + g * step;
            centerCount++;
           }
        }

      if(centerCount == 0)
         return false;

      //--- Pertenencia dura: cada punto se asigna al centro más cercano dentro de zoneWidth
      double zoneWidth = zoneWidthAtrMul * atrRef;

      ArrayResize(zonesOut, centerCount);
      for(int z = 0; z < centerCount; z++)
        {
         zonesOut[z].timeframe = timeframe;
         zonesOut[z].center    = centers[z];
         zonesOut[z].atrRef    = atrRef;
         ArrayResize(zonesOut[z].pointIdx, 0);
        }

      for(int j = 0; j < m; j++)
        {
         double bestDist = -1.0;
         int    bestZone = -1;

         for(int z = 0; z < centerCount; z++)
           {
            double d = MathAbs(points[j].price - centers[z]);
            if(d > zoneWidth)
               continue;
            if(bestZone < 0 || d < bestDist)
              {
               bestDist = d;
               bestZone = z;
              }
           }

         if(bestZone >= 0)
           {
            int n = ArraySize(zonesOut[bestZone].pointIdx);
            ArrayResize(zonesOut[bestZone].pointIdx, n + 1, m);
            zonesOut[bestZone].pointIdx[n] = j;
           }
        }

      //--- Descarta zonas con menos toques que el mínimo exigido.
      //---
      //--- Un "toque" es una VELA distinta, no un punto: como cada vela aporta su máximo
      //--- y su mínimo, contar puntos permitiría que una sola vela ancha (con ambos
      //--- extremos dentro de la zona) valiera por dos, y una zona de 2 velas pasaría el
      //--- mínimo de 3. El ajuste WLS y N_eff siguen usando TODOS los puntos: esto solo
      //--- cambia el criterio de descarte.
      //---
      //--- Se cuenta con un array de sellos indexado por barShift (en vez de comparar
      //--- todos contra todos): O(puntos) en total y sin asumir ningún orden previo.
      int maxBarShift = 0;
      for(int j = 0; j < m; j++)
         if(points[j].barShift > maxBarShift)
            maxBarShift = points[j].barShift;

      int barStamp[];
      ArrayResize(barStamp, maxBarShift + 1);
      ArrayInitialize(barStamp, -1);

      SLevelZone kept[];
      int keptCount = 0;
      ArrayResize(kept, centerCount);
      for(int z = 0; z < centerCount; z++)
        {
         int distinctBars = 0;
         int pointCount   = ArraySize(zonesOut[z].pointIdx);

         for(int i = 0; i < pointCount; i++)
           {
            int shift = points[zonesOut[z].pointIdx[i]].barShift;
            if(barStamp[shift] == z)
               continue; // esta vela ya se contó para esta zona
            barStamp[shift] = z;
            distinctBars++;
           }

         zonesOut[z].distinctBars = distinctBars; // se conserva para mostrarlo al usuario más adelante

         if(distinctBars >= minTouches)
           {
            kept[keptCount] = zonesOut[z];
            keptCount++;
           }
        }

      ArrayResize(zonesOut, keptCount);
      for(int z = 0; z < keptCount; z++)
         zonesOut[z] = kept[z];

      return (keptCount > 0);
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 8/17 - CLevelFitter (pasos 3-4): minimos cuadrados ponderados + puntaje
//==================================================================+

//+------------------------------------------------------------------+
//|                                                  LevelFitter.mqh |
//|  CLevelFitter: pasos 3-4 — ajusta cada zona por mínimos          |
//|  cuadrados ponderados y calcula su puntaje (ver PLAN.md §3.3-3.5)|
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| CLevelFitter: sin estado entre llamadas. Recibe todos los       |
//| parámetros de puntaje explícitos para que LevelRepository        |
//| controle los inputs "Puntaje".                                   |
//+------------------------------------------------------------------+
class CLevelFitter
  {
public:
   //--- Ajusta una zona: calcula L* (WLS), sigma, N_eff y el puntaje bruto (sin
   //--- escalar por temporalidad — eso lo hace LevelRepository en el paso 5).
   //--- 'atrT'    = ATR de la temporalidad de la zona (usado en pesos y sigma normalizada).
   //--- 'atrBase' = ATR de la temporalidad base (usado en la penalización por distancia,
   //--- para que todos los niveles compitan con la misma vara de "distancia relevante hoy").
   bool              FitZone(const SPricePoint &points[],
                              const SLevelZone &zone,
                              double currentPrice,
                              double atrT,
                              double atrBase,
                              double relevanceRangeAtrMul,
                              double minWeight,
                              double distPenaltyLambda,
                              double touchExponent,
                              double minSigmaAtr,
                              double timeDecayHalfLife,
                              SLevel &levelOut)
     {
      int n = ArraySize(zone.pointIdx);
      if(n == 0 || atrT <= 0.0 || atrBase <= 0.0)
         return false;

      double dMax = relevanceRangeAtrMul * atrT;
      if(dMax <= 0.0)
         return false;

      //--- Dos pesos por punto, con roles separados:
      //---  - wTime (antigüedad): define DÓNDE está el nivel. Los toques recientes
      //---    describen mejor la estructura vigente; no sesga hacia ningún precio.
      //---  - wDist (distancia al precio actual, paso 4a): solo entra en el PUNTAJE vía
      //---    N_eff. Usarlo en la media desplazaba sistemáticamente L* hacia el precio
      //---    actual, porque los puntos del lado cercano de la zona pesaban más.
      double timeWeights[];
      ArrayResize(timeWeights, n);
      double sumTimeW = 0.0;
      double nEff     = 0.0;

      for(int i = 0; i < n; i++)
        {
         int    idx   = zone.pointIdx[i];
         double wTime = (timeDecayHalfLife > 0.0) ? MathPow(0.5, points[idx].barShift / timeDecayHalfLife) : 1.0;

         double d     = MathAbs(points[idx].price - currentPrice);
         double wDist = MathMax(1.0 - d / dMax, minWeight);

         timeWeights[i] = wTime;
         sumTimeW      += wTime;
         nEff          += wTime * wDist;
        }

      if(sumTimeW <= 0.0 || nEff <= 0.0)
         return false;

      //--- Paso 3: L* = media ponderada por antigüedad (solución cerrada del mínimo cuadrático)
      double sumWP = 0.0;
      for(int i = 0; i < n; i++)
         sumWP += timeWeights[i] * points[zone.pointIdx[i]].price;
      double lStar = sumWP / sumTimeW;

      //--- Dispersión residual ponderada, normalizada por ATR de la TF de la zona
      double sumWResidual = 0.0;
      for(int i = 0; i < n; i++)
        {
         double diff = points[zone.pointIdx[i]].price - lStar;
         sumWResidual += timeWeights[i] * diff * diff;
        }
      double sigma    = MathSqrt(sumWResidual / sumTimeW);
      double sigmaAtr = sigma / atrT;

      //--- Paso 4b: penalización por distancia del nivel al precio actual (en ATR base)
      double distInAtrBase = MathAbs(lStar - currentPrice) / atrBase;
      double penalty       = 1.0 + distPenaltyLambda * distInAtrBase;

      double sigmaAtrFloored = MathMax(sigmaAtr, minSigmaAtr);
      double touchDivisor    = MathPow(nEff, touchExponent);
      if(touchDivisor <= 0.0)
         touchDivisor = 1.0;

      double scoreRaw = (sigmaAtrFloored / touchDivisor) * penalty;

      levelOut.price        = lStar;
      levelOut.sigma        = sigma;
      levelOut.sigmaAtr     = sigmaAtr;
      levelOut.effTouches   = nEff;
      levelOut.touchCandles = zone.distinctBars;
      levelOut.scoreRaw     = scoreRaw;
      levelOut.score        = scoreRaw; // LevelRepository aplica el factor de TF (paso 5)
      levelOut.timeframe    = zone.timeframe;
      levelOut.tfMask       = TimeframeToBit(zone.timeframe);
      levelOut.confluence   = 1;
      levelOut.isResistance = (lStar > currentPrice);

      return true;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 9/17 - CLevelRepository (pasos 5-6): multi-TF, cache, fusion, seleccion
//==================================================================+

//+------------------------------------------------------------------+
//|                                              LevelRepository.mqh |
//|  CLevelRepository: pasos 5-6 — recorre el abanico M5..D1, cachea|
//|  puntos/zonas por temporalidad, escala puntajes, fusiona por    |
//|  confluencia y selecciona los mejores niveles (ver PLAN.md §3.6-|
//|  §3.7 y §4).                                                      |
//+------------------------------------------------------------------+


//--- 6 temporalidades del abanico fijo (M5..D1) + 1 slot para una TF base que no
//--- pertenezca al abanico (M1, M2, H2, H3...). Sin ese slot extra, un gráfico M1
//--- con todo el abanico habilitado desborda los arrays de tamaño fijo.
#define SRMTF_MAX_TF 7

//--- Caché por temporalidad: puntos y zonas del último recálculo de esa TF
struct STfCache
  {
   ENUM_TIMEFRAMES  tf;
   bool             ready;      // true si hubo historial suficiente para analizarla
   SPricePoint      points[];
   SLevelZone       zones[];
  };

//+------------------------------------------------------------------+
//| CLevelRepository                                                  |
//+------------------------------------------------------------------+
class CLevelRepository
  {
private:
   CPointCollector   m_collector;
   CZoneFinder       m_zoneFinder;
   CLevelFitter      m_fitter;

   ENUM_TIMEFRAMES   m_baseTf;
   ENUM_TIMEFRAMES   m_tfs[SRMTF_MAX_TF];
   CBarMonitor       m_tfBarMonitors[SRMTF_MAX_TF];
   STfCache          m_cache[SRMTF_MAX_TF];
   int               m_tfCount;

   //--- Parámetros "Detección de Niveles" / "Clustering (KDE)"
   int               m_minTouches;
   double            m_kdeBandwidthAtrMul;
   int               m_kdeGridNodes;
   double            m_minDensityRatio;
   double            m_zoneWidthAtrMul;

   //--- Parámetros "Puntaje"
   double            m_relevanceRangeAtrMul;
   double            m_minWeight;
   double            m_distPenaltyLambda;
   double            m_touchExponent;
   double            m_minSigmaAtr;
   double            m_timeDecayHalfLife;

   //--- Parámetros "Multi-Temporalidad"
   double            m_tfExponent;
   double            m_mergeToleranceAtrMul;
   double            m_confluenceBonus;

   //--- Parámetros "Selección de Líneas"
   int               m_maxLinesAbove;
   int               m_maxLinesBelow;
   double            m_minSeparationAtrMul;

   //--- Resultado del último recálculo completo
   SLevel            m_resistances[];
   SLevel            m_supports[];

   int               PopCount(int mask)
     {
      int c = 0;
      while(mask != 0)
        {
         c += (mask & 1);
         mask >>= 1;
        }
      return c;
     }

   //--- Copia profunda de un array de SLevelZone: ArrayCopy() no admite structs con
   //--- arrays dinámicos anidados (pointIdx[]); la asignación struct-a-struct sí hace
   //--- deep copy nativo en MQL5, así que se aplica elemento a elemento.
   void              CopyZones(SLevelZone &dst[], const SLevelZone &src[])
     {
      int n = ArraySize(src);
      ArrayResize(dst, n);
      for(int i = 0; i < n; i++)
         dst[i] = src[i];
     }

   //--- Inserción ordenada ascendente por PeriodSeconds, sin duplicados
   void              InsertSorted(ENUM_TIMEFRAMES &list[], int &count, ENUM_TIMEFRAMES tf)
     {
      for(int i = 0; i < count; i++)
         if(list[i] == tf)
            return; // ya presente

      //--- Guarda defensiva: el dimensionamiento de SRMTF_MAX_TF ya contempla el peor
      //--- caso (base fuera del abanico + las 6 TFs), pero un desborde aquí sería un
      //--- error crítico de runtime, no un fallo silencioso.
      if(count >= ArraySize(list))
        {
         Print(__FUNCTION__, ": lista de temporalidades llena (", ArraySize(list),
               "); se ignora ", EnumToString(tf));
         return;
        }

      int pos = count;
      for(int i = 0; i < count; i++)
        {
         if(PeriodSeconds(tf) < PeriodSeconds(list[i]))
           {
            pos = i;
            break;
           }
        }
      for(int i = count; i > pos; i--)
         list[i] = list[i - 1];
      list[pos] = tf;
      count++;
     }

   //--- Fusiona candidatos por confluencia (complete-linkage 1D) y aplica selección final
   void              MergeAndSelect(SLevel &candidates[], int candCount, double currentPrice, double atrBase)
     {
      ArrayResize(m_resistances, 0);
      ArrayResize(m_supports, 0);

      if(candCount == 0)
         return;

      //--- Orden ascendente por precio (insertion sort; candCount es pequeño)
      for(int i = 1; i < candCount; i++)
        {
         SLevel key = candidates[i];
         int j = i - 1;
         while(j >= 0 && candidates[j].price > key.price)
           {
            candidates[j + 1] = candidates[j];
            j--;
           }
         candidates[j + 1] = key;
        }

      double tolerance = m_mergeToleranceAtrMul * atrBase;

      SLevel merged[];
      int    mergedCount = 0;
      ArrayResize(merged, candCount);

      int groupStart = 0;
      while(groupStart < candCount)
        {
         //--- Se acota el ANCHO TOTAL del grupo (último - primero), no la distancia entre
         //--- vecinos: con chain-linkage, niveles separados 0.5 ATR entre sí se encadenaban
         //--- y fundían en un solo nivel candidatos a varios ATR de distancia.
         int groupEnd = groupStart + 1; // exclusivo
         while(groupEnd < candCount && (candidates[groupEnd].price - candidates[groupStart].price) <= tolerance)
            groupEnd++;

         double sumInvScore = 0.0, sumPriceInvScore = 0.0, sumSigmaInvScore = 0.0, minScore = DBL_MAX;
         int    tfMaskUnion = 0;

         for(int i = groupStart; i < groupEnd; i++)
           {
            double s = MathMax(candidates[i].score, 1.0e-12); // evita división por cero
            double w = 1.0 / s;
            sumInvScore      += w;
            sumPriceInvScore += w * candidates[i].price;
            sumSigmaInvScore += w * candidates[i].sigma;
            if(candidates[i].score < minScore)
               minScore = candidates[i].score;
            tfMaskUnion |= candidates[i].tfMask;
           }

         int k = PopCount(tfMaskUnion);
         if(k == 0)
            k = 1; // seguridad: TF fuera del abanico fijo (p.ej. base = M1) no aporta bit

         SLevel lvl;
         lvl.price        = sumPriceInvScore / sumInvScore;
         lvl.score         = minScore / (1.0 + m_confluenceBonus * (k - 1));
         lvl.scoreRaw       = minScore;
         lvl.tfMask         = tfMaskUnion;
         lvl.confluence     = k;
         lvl.timeframe       = candidates[groupStart].timeframe; // referencia informativa
         lvl.isResistance   = (lvl.price > currentPrice);
         lvl.sigma          = sumSigmaInvScore / sumInvScore; // para dibujar la zona L ± sigma
         lvl.sigmaAtr       = 0.0; // ya no comparable entre TFs tras fusionar; no se usa aguas abajo
         lvl.effTouches     = 0.0;
         lvl.touchCandles   = 0;
         for(int i = groupStart; i < groupEnd; i++)
           {
            lvl.effTouches   += candidates[i].effTouches;
            lvl.touchCandles += candidates[i].touchCandles; // suma de velas distintas por cada TF fusionada
           }

         merged[mergedCount] = lvl;
         mergedCount++;

         groupStart = groupEnd;
        }

      //--- Separa por lado del precio
      SLevel resCand[], supCand[];
      int resN = 0, supN = 0;
      ArrayResize(resCand, mergedCount);
      ArrayResize(supCand, mergedCount);

      for(int i = 0; i < mergedCount; i++)
        {
         if(merged[i].isResistance)
           {
            resCand[resN] = merged[i];
            resN++;
           }
         else
           {
            supCand[supN] = merged[i];
            supN++;
           }
        }

      //--- Orden ascendente por score (menor = mejor) dentro de cada lado
      SortByScore(resCand, resN);
      SortByScore(supCand, supN);

      //--- Separación mínima en ATR base: un umbral en precio absoluto solo tiene
      //--- sentido para un instrumento y un régimen de volatilidad concretos.
      double minSeparation = m_minSeparationAtrMul * atrBase;
      SelectWithSeparation(resCand, resN, m_maxLinesAbove, minSeparation, m_resistances);
      SelectWithSeparation(supCand, supN, m_maxLinesBelow, minSeparation, m_supports);
     }

   void              SortByScore(SLevel &arr[], int n)
     {
      for(int i = 1; i < n; i++)
        {
         SLevel key = arr[i];
         int j = i - 1;
         while(j >= 0 && arr[j].score > key.score)
           {
            arr[j + 1] = arr[j];
            j--;
           }
         arr[j + 1] = key;
        }
     }

   //--- Selección greedy: recorre por puntaje ascendente, acepta si respeta separación mínima
   //--- respecto de todo lo ya aceptado, hasta completar 'maxLines'.
   void              SelectWithSeparation(SLevel &sorted[], int n, int maxLines, double minSeparation, SLevel &out[])
     {
      ArrayResize(out, 0);
      int accepted = 0;

      for(int i = 0; i < n && accepted < maxLines; i++)
        {
         bool farEnough = true;
         for(int j = 0; j < accepted; j++)
           {
            if(MathAbs(sorted[i].price - out[j].price) < minSeparation)
              {
               farEnough = false;
               break;
              }
           }
         if(!farEnough)
            continue;

         ArrayResize(out, accepted + 1);
         out[accepted] = sorted[i];
         accepted++;
        }
     }

public:
                     CLevelRepository(void) : m_tfCount(0) {}

   //--- Registra las temporalidades activas (base + abanico M5..D1 estrictamente
   //--- superior a la base, según §3.6 — todo el abanico se analiza siempre), crea sus
   //--- handles de ATR y prepara el caché. Llamar solo desde OnInit.
   bool              Init(ENUM_TIMEFRAMES baseTf,
                           int barsToAnalyze, int minTouches,
                           double kdeBandwidthAtrMul, int kdeGridNodes, double minDensityRatio, double zoneWidthAtrMul,
                           double relevanceRangeAtrMul, double minWeight, double distPenaltyLambda,
                           double touchExponent, double minSigmaAtr, double timeDecayHalfLife,
                           double tfExponent, double mergeToleranceAtrMul, double confluenceBonus,
                           int maxLinesAbove, int maxLinesBelow, double minSeparationAtrMul,
                           CAtrProvider &atr)
     {
      m_baseTf = baseTf;

      m_minTouches           = MathMax(2, minTouches);
      m_kdeBandwidthAtrMul   = kdeBandwidthAtrMul;
      m_kdeGridNodes         = MathMax(10, kdeGridNodes);
      m_minDensityRatio      = minDensityRatio;
      m_zoneWidthAtrMul      = zoneWidthAtrMul;
      m_relevanceRangeAtrMul = relevanceRangeAtrMul;
      m_minWeight            = minWeight;
      m_distPenaltyLambda    = distPenaltyLambda;
      m_touchExponent        = touchExponent;
      m_minSigmaAtr          = minSigmaAtr;
      m_timeDecayHalfLife    = MathMax(0.0, timeDecayHalfLife);
      m_tfExponent           = tfExponent;
      m_mergeToleranceAtrMul = mergeToleranceAtrMul;
      m_confluenceBonus      = confluenceBonus;
      m_maxLinesAbove        = MathMax(0, maxLinesAbove);
      m_maxLinesBelow        = MathMax(0, maxLinesBelow);
      m_minSeparationAtrMul  = MathMax(0.0, minSeparationAtrMul);

      m_collector.SetBarsToAnalyze(barsToAnalyze);

      //--- Construye la lista de TFs activas: base (siempre) + abanico fijo M5..D1
      //--- estrictamente superior a la base (paso 5 del plan, §3.6).
      ENUM_TIMEFRAMES fan[6] = { PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1 };

      ENUM_TIMEFRAMES active[SRMTF_MAX_TF];
      int             activeCount = 0;

      InsertSorted(active, activeCount, baseTf); // la base siempre se analiza

      for(int i = 0; i < 6; i++)
        {
         if(PeriodSeconds(fan[i]) <= PeriodSeconds(baseTf))
            continue; // por debajo o igual a la base: ya cubierto o fuera de alcance
         InsertSorted(active, activeCount, fan[i]);
        }

      m_tfCount = activeCount;
      for(int i = 0; i < m_tfCount; i++)
        {
         m_tfs[i] = active[i];
         m_tfBarMonitors[i].Init(active[i]);
         m_cache[i].tf    = active[i];
         m_cache[i].ready = false;

         if(!atr.Register(active[i]))
            return false;
        }

      if(m_tfCount == 0)
        {
         Print(__FUNCTION__, ": no quedó ninguna temporalidad activa en el abanico");
         return false;
        }

      return true;
     }

   //--- true cuando todas las TFs activas tienen historial suficiente ya cacheado.
   //--- El EA no debe operar (ni dibujar) hasta que esto sea true.
   bool              IsFullyReady(void)
     {
      for(int i = 0; i < m_tfCount; i++)
         if(!m_cache[i].ready)
            return false;
      return true;
     }

   //--- Pasos 1-2: recalcula puntos+zonas de cada TF SOLO si le cerró una vela nueva
   //--- (caché por TF, ver §4 del plan). Llamar en cada tick nuevo de la TF base.
   void              RefreshZones(CAtrProvider &atr)
     {
      for(int i = 0; i < m_tfCount; i++)
        {
         bool mustRecompute = m_tfBarMonitors[i].IsNewBar() || !m_cache[i].ready;
         if(!mustRecompute)
            continue;

         //--- IsNewBar() ya consumió el evento de vela nueva de esta TF. Si a partir de
         //--- aquí algo falla, hay que invalidar el caché: dejarlo como 'ready' con las
         //--- zonas de la vela anterior haría operar sobre niveles rancios hasta el
         //--- siguiente cierre de esa TF (hasta 24 h en D1). Con ready=false se reintenta
         //--- en la próxima vela base y, mientras tanto, IsFullyReady() bloquea la operativa.
         m_cache[i].ready = false;

         if(!m_collector.IsReady(m_tfs[i]))
            continue; // historial insuficiente todavía; se reintenta en el próximo tick

         SPricePoint pts[];
         if(!m_collector.Collect(m_tfs[i], pts))
            continue;

         double atrT;
         if(!atr.GetValue(m_tfs[i], 1, atrT))
            continue;

         SLevelZone zones[];
         m_zoneFinder.FindZones(pts, m_tfs[i], atrT,
                                 m_kdeBandwidthAtrMul, m_zoneWidthAtrMul, m_minDensityRatio,
                                 m_kdeGridNodes, m_minTouches, zones);

         //--- ArrayCopy no reduce el destino: sin el resize previo, un refresco que
         //--- devuelva menos velas dejaría puntos rancios en la cola del caché.
         ArrayResize(m_cache[i].points, ArraySize(pts));
         ArrayCopy(m_cache[i].points, pts); // SPricePoint no tiene arrays dinámicos: ArrayCopy es válido
         CopyZones(m_cache[i].zones, zones); // SLevelZone SÍ tiene un array dinámico (pointIdx[]):
                                              // ArrayCopy() lo rechaza (error 216); se copia elemento
                                              // a elemento vía asignación de struct (deep copy nativo)
         m_cache[i].ready = true;
        }
     }

   //--- Pasos 3-6: reajusta (WLS+puntaje), escala por TF, funde por confluencia y
   //--- selecciona los mejores niveles. Llamar en cada vela nueva de la TF base
   //--- (después de RefreshZones), ya que 'currentPrice' cambia cada vela base.
   bool              RecomputeLevels(double currentPrice, CAtrProvider &atr)
     {
      if(!IsFullyReady())
         return false;

      double atrBase;
      if(!atr.GetValue(m_baseTf, 1, atrBase) || atrBase <= 0.0)
         return false;

      SLevel candidates[];
      int    candCount = 0;

      for(int i = 0; i < m_tfCount; i++)
        {
         double atrT;
         if(!atr.GetValue(m_tfs[i], 1, atrT) || atrT <= 0.0)
            continue;

         double ratio    = (double)PeriodSeconds(m_tfs[i]) / (double)PeriodSeconds(m_baseTf);
         double tfFactor = MathPow(ratio, m_tfExponent);
         if(tfFactor <= 0.0)
            tfFactor = 1.0;

         int zoneCount = ArraySize(m_cache[i].zones);
         for(int z = 0; z < zoneCount; z++)
           {
            SLevel lvl;
            if(!m_fitter.FitZone(m_cache[i].points, m_cache[i].zones[z], currentPrice, atrT, atrBase,
                                  m_relevanceRangeAtrMul, m_minWeight, m_distPenaltyLambda,
                                  m_touchExponent, m_minSigmaAtr, m_timeDecayHalfLife, lvl))
               continue;

            lvl.score = lvl.scoreRaw / tfFactor; // paso 5: escala por temporalidad

            ArrayResize(candidates, candCount + 1, 64);
            candidates[candCount] = lvl;
            candCount++;
           }
        }

      MergeAndSelect(candidates, candCount, currentPrice, atrBase);
      return true;
     }

   int               GetResistanceCount(void) { return ArraySize(m_resistances); }
   int               GetSupportCount(void)    { return ArraySize(m_supports); }

   bool              GetResistance(int i, SLevel &out)
     {
      if(i < 0 || i >= ArraySize(m_resistances))
         return false;
      out = m_resistances[i];
      return true;
     }

   bool              GetSupport(int i, SLevel &out)
     {
      if(i < 0 || i >= ArraySize(m_supports))
         return false;
      out = m_supports[i];
      return true;
     }

   //--- Copias completas para el renderer y el log verboso (SLevel no contiene
   //--- arrays dinámicos, así que ArrayCopy es válido elemento a elemento).
   void              GetResistances(SLevel &out[]) { ArrayCopy(out, m_resistances); }
   void              GetSupports(SLevel &out[])    { ArrayCopy(out, m_supports); }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 10/17 - CVolumeFilter: regla 1 (volumen > SMA)
//==================================================================+

//+------------------------------------------------------------------+
//|                                                 VolumeFilter.mqh |
//|  CVolumeFilter: regla 1 del estándar — volumen de la vela        |
//|  recién cerrada > promedio de las N previas (no incluye la vela |
//|  evaluada). Usa volumen real si el símbolo lo provee, con        |
//|  fallback automático a tick volume.                              |
//+------------------------------------------------------------------+

class CVolumeFilter
  {
private:
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_period;
   bool              m_useRealVolumeIfAvailable;

   //--- Copia volumen [shift, shift+count-1] directamente en 'out' (as-series: índice 0
   //--- = vela 'shift'); intenta volumen real primero (si está habilitado) y cae a tick
   //--- volume si no hay datos reales para ese rango. Se copia directo al destino, sin
   //--- ArrayCopy intermedio: copiar entre un array as-series y uno que no lo es deja
   //--- el orden dependiente del flag de indexación, e índice 0 dejaría de ser la vela
   //--- evaluada.
   bool              CopyVolumeRange(int shift, int count, long &out[])
     {
      ArraySetAsSeries(out, true);

      if(m_useRealVolumeIfAvailable)
        {
         int copiedReal = CopyRealVolume(_Symbol, m_timeframe, shift, count, out);
         if(copiedReal == count)
           {
            long sum = 0;
            for(int i = 0; i < copiedReal; i++)
               sum += out[i];
            if(sum > 0) // volumen real disponible y no todo-cero: el símbolo sí lo reporta
               return true;
           }
        }

      int copiedTick = CopyTickVolume(_Symbol, m_timeframe, shift, count, out);
      if(copiedTick != count)
        {
         Print(__FUNCTION__, ": error copiando volumen, code=", GetLastError());
         return false;
        }

      return true;
     }

public:
                     CVolumeFilter(void) : m_timeframe(PERIOD_CURRENT),
                                            m_period(20),
                                            m_useRealVolumeIfAvailable(true) {}

   void              Init(ENUM_TIMEFRAMES timeframe, int period, bool useRealVolumeIfAvailable)
     {
      m_timeframe                = timeframe;
      m_period                   = period;
      m_useRealVolumeIfAvailable = useRealVolumeIfAvailable;
     }

   //--- Regla 1: volumen de la última vela cerrada (shift 1) > promedio de las
   //--- m_period velas previas a esa (shift 2..m_period+1).
   //---
   //--- Se copia TODO el rango en una sola llamada, a propósito. Con dos llamadas
   //--- separadas, el fallback real→tick se decide de forma independiente en cada una:
   //--- si la vela evaluada tuviera volumen real 0 (instrumento ilíquido, borde de
   //--- sesión) pero las previas no, se compararía un volumen de ticks contra un
   //--- promedio de volumen real — dos escalas distintas, comparación sin sentido.
   bool              IsVolumeConfirmed(void)
     {
      int count = m_period + 1;

      long volumes[];
      if(!CopyVolumeRange(1, count, volumes))
         return false;

      long sum = 0;
      for(int i = 1; i < count; i++) // índice 0 = vela evaluada; se excluye del promedio
         sum += volumes[i];

      double avg = (double)sum / (double)m_period;
      return (double)volumes[0] > avg;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 11/17 - CRsiFilter: regla 2 (RSI direccional)
//==================================================================+

//+------------------------------------------------------------------+
//|                                                    RsiFilter.mqh |
//|  CRsiFilter: regla 2 del estándar — filtro RSI direccional.      |
//|  No es parte de la estrategia original del usuario; se incluye  |
//|  por el estándar mql5-ea-dev y es desactivable con               |
//|  InpUseRsiFilter (ver Expert.mqh).                                |
//+------------------------------------------------------------------+

class CRsiFilter
  {
private:
   int               m_handle;
   double            m_overbought;
   double            m_oversold;

public:
                     CRsiFilter(void) : m_handle(INVALID_HANDLE), m_overbought(70.0), m_oversold(30.0) {}

   bool              Init(ENUM_TIMEFRAMES timeframe, int period, double overbought, double oversold)
     {
      m_overbought = overbought;
      m_oversold   = oversold;

      m_handle = iRSI(_Symbol, timeframe, period, PRICE_CLOSE);
      if(m_handle == INVALID_HANDLE)
        {
         Print(__FUNCTION__, ": no se pudo crear el handle de RSI, code=", GetLastError());
         return false;
        }
      return true;
     }

   void              Deinit(void)
     {
      if(m_handle != INVALID_HANDLE)
         IndicatorRelease(m_handle);
     }

   //--- direction: 1 = compra propuesta, -1 = venta propuesta.
   //--- Nunca comprar en sobrecompra, nunca vender en sobreventa (comprar en
   //--- sobreventa o vender en sobrecompra SÍ está permitido).
   bool              IsAllowed(int direction)
     {
      double buffer[];
      ArraySetAsSeries(buffer, true);

      if(CopyBuffer(m_handle, 0, 1, 1, buffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando RSI, code=", GetLastError());
         return false;
        }

      double rsi = buffer[0];

      if(direction == 1 && rsi >= m_overbought)
         return false;
      if(direction == -1 && rsi <= m_oversold)
         return false;

      return true;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 12/17 - CTrendFilter: pendiente de la EMA 200
//==================================================================+

//+------------------------------------------------------------------+
//|                                                   TrendFilter.mqh |
//|  CTrendFilter: pendiente de la EMA 200 en la TF elegida por el   |
//|  usuario, para el modo de operativa DIR_TREND_FOLLOW.            |
//+------------------------------------------------------------------+

class CTrendFilter
  {
private:
   int               m_handle;
   ENUM_TIMEFRAMES   m_timeframe;

public:
                     CTrendFilter(void) : m_handle(INVALID_HANDLE), m_timeframe(PERIOD_CURRENT) {}

   bool              Init(ENUM_TIMEFRAMES timeframe, int emaPeriod)
     {
      m_timeframe = timeframe;

      m_handle = iMA(_Symbol, timeframe, emaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(m_handle == INVALID_HANDLE)
        {
         Print(__FUNCTION__, ": no se pudo crear el handle de EMA, code=", GetLastError());
         return false;
        }
      return true;
     }

   void              Deinit(void)
     {
      if(m_handle != INVALID_HANDLE)
         IndicatorRelease(m_handle);
     }

   //--- Dirección de tendencia: 1 = alcista (solo compras), -1 = bajista (solo ventas),
   //--- 0 = lateral (sin operaciones). slope = EMA[1] - EMA[1+slopeBars],
   //--- comparado contra un umbral en múltiplos de ATR de esta TF.
   bool              GetDirection(int slopeBars, double thresholdAtrMul, double atrTrend, int &directionOut)
     {
      double buffer[];
      ArraySetAsSeries(buffer, true);

      //--- Debe exigirse la copia COMPLETA, no solo '> 0': CopyBuffer redimensiona el
      //--- destino a lo que realmente copió, así que una copia parcial durante el
      //--- calentamiento de la EMA 200 dejaría buffer[slopeBars] fuera de rango.
      int need = slopeBars + 1;
      int copied = CopyBuffer(m_handle, 0, 1, need, buffer);
      if(copied < need)
        {
         Print(__FUNCTION__, ": EMA aún sin datos suficientes (copiados=", copied,
               ", necesarios=", need, "), code=", GetLastError());
         return false;
        }

      //--- buffer está en orden 'as series': índice 0 = shift 1, índice slopeBars = shift 1+slopeBars
      double emaNow  = buffer[0];
      double emaPast = buffer[slopeBars];
      double slope   = emaNow - emaPast;

      double threshold = thresholdAtrMul * atrTrend;

      if(slope > threshold)
         directionOut = 1;
      else if(slope < -threshold)
         directionOut = -1;
      else
         directionOut = 0;

      return true;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 13/17 - CSignalEngine (paso 7): toque + rechazo confirmado
//==================================================================+

//+------------------------------------------------------------------+
//|                                                  SignalEngine.mqh |
//|  CSignalEngine: paso 7 — evalúa toque + rechazo confirmado sobre |
//|  los niveles seleccionados, aplica dirección/tendencia y los     |
//|  filtros obligatorios de volumen y RSI (ver PLAN.md §3.8).       |
//+------------------------------------------------------------------+


//--- Un disparo registrado sobre un nivel: su precio y la vela base en que ocurrió
struct SLevelShot
  {
   double           price;
   datetime         barTime;
  };

//+------------------------------------------------------------------+
//| CLevelCooldown: tiempo de espera por nivel (InpLevelCooldownBars).|
//| En modo inmediato, si el precio queda dentro de la zona de un     |
//| nivel varios ticks seguidos, sin esto el EA vuelve a entrar en    |
//| cada tick hasta llenar el cupo de posiciones. Un nivel ya operado |
//| queda bloqueado durante N velas base completas.                   |
//| Los niveles se recalculan en cada vela base y su precio se mueve  |
//| levemente, así que la identidad de un nivel se reconoce por       |
//| cercanía de precio (tolerancia de zona), no por igualdad exacta.  |
//+------------------------------------------------------------------+
class CLevelCooldown
  {
private:
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_bars;
   SLevelShot        m_shots[];

   int               BarsSince(datetime barTime)
     {
      int shift = iBarShift(_Symbol, m_timeframe, barTime, false);
      return (shift < 0) ? INT_MAX : shift; // sin historial para ubicarla: se da por vencida
     }

   void              PruneExpired(void)
     {
      int n    = ArraySize(m_shots);
      int kept = 0;
      for(int i = 0; i < n; i++)
        {
         if(BarsSince(m_shots[i].barTime) >= m_bars)
            continue;
         m_shots[kept] = m_shots[i];
         kept++;
        }
      ArrayResize(m_shots, kept);
     }

public:
                     CLevelCooldown(void) : m_timeframe(PERIOD_CURRENT), m_bars(0) {}

   void              Init(ENUM_TIMEFRAMES timeframe, int bars)
     {
      m_timeframe = timeframe;
      m_bars      = MathMax(0, bars);
      ArrayResize(m_shots, 0);
     }

   bool              IsCoolingDown(double levelPrice, double tolerance)
     {
      if(m_bars <= 0)
         return false;

      PruneExpired();
      for(int i = 0; i < ArraySize(m_shots); i++)
         if(MathAbs(m_shots[i].price - levelPrice) <= tolerance)
            return true;
      return false;
     }

   //--- Llamar solo cuando la orden se ejecutó: un intento rechazado no consume el nivel
   void              Register(double levelPrice)
     {
      if(m_bars <= 0)
         return;

      int n = ArraySize(m_shots);
      ArrayResize(m_shots, n + 1, 16);
      m_shots[n].price   = levelPrice;
      m_shots[n].barTime = iTime(_Symbol, m_timeframe, 0);
     }
  };

class CSignalEngine
  {
private:
   //--- Rechazo en resistencia: la vela viene DESDE ABAJO (open < L), va a buscar la
   //--- línea (high la alcanza dentro de la tolerancia) y es rechazada (close < L).
   //---
   //--- La condición sobre 'open' no es redundante. Los niveles se clasifican como
   //--- resistencia/soporte contra Close[1] (Expert.mqh), que es el MISMO cierre que se
   //--- evalúa aquí: por construcción todo nivel clasificado resistencia cumple
   //--- close1 < L, y todo soporte cumple close1 > L. Sin el filtro de apertura, una
   //--- vela que ROMPE una resistencia queda reclasificada como soporte y su mecha
   //--- inferior la haría pasar por rebote: el EA compraría la propia vela de ruptura,
   //--- justo lo contrario de la estrategia especificada (que solo opera el rechazo).
   bool              CheckResistanceTouch(const SLevel &lvl, double open1, double high1, double close1, double tol)
     {
      return (open1 < lvl.price) && (high1 >= lvl.price - tol) && (close1 < lvl.price);
     }

   //--- Rebote en soporte: la vela viene DESDE ARRIBA (open > L), perfora la zona con
   //--- la mecha y cierra de vuelta por encima.
   bool              CheckSupportTouch(const SLevel &lvl, double open1, double low1, double close1, double tol)
     {
      return (open1 > lvl.price) && (low1 <= lvl.price + tol) && (close1 > lvl.price);
     }

   //--- Toque inmediato (InpRequireConfirmation = false): no espera el cierre de la
   //--- vela ni el patrón de rechazo, solo que el precio actual entre en la zona del
   //--- nivel (|precio - L| <= tolerancia). Se evalúa contra el precio AL QUE SE
   //--- EJECUTARÍA la orden (Ask en compra, Bid en venta) y no contra Bid en ambos
   //--- casos: OpenPosition() abre a Ask en las compras, así que comparar con Bid
   //--- desplazaba la línea dibujada (lvl.price) todo el spread por debajo del precio
   //--- real de entrada en cada compra confirmada por este modo.
   //---
   //--- Además exige que la vela en curso haya ABIERTO del lado correcto del nivel
   //--- (sobre el soporte / bajo la resistencia), igual que el filtro de 'open' del modo
   //--- confirmado. Solo con la distancia absoluta, un soporte ya perforado que el precio
   //--- vuelve a tocar DESDE ABAJO disparaba una compra en pleno retest bajista.
   bool              CheckZoneTouchNow(const SLevel &lvl, double execPrice, double open0, double tol, bool isSupport)
     {
      bool approachedFromCorrectSide = isSupport ? (open0 > lvl.price) : (open0 < lvl.price);
      return approachedFromCorrectSide && MathAbs(execPrice - lvl.price) <= tol;
     }

public:
   //--- En modo confirmado (requireConfirmation = true) se evalúa una sola vez por vela
   //--- nueva de la TF base (regla 3 del estándar): exige volumen confirmado y el patrón
   //--- de rechazo sobre la vela recién cerrada. En modo inmediato (false) se evalúa en
   //--- cada tick contra el precio actual: basta con que toque la zona del nivel, sin
   //--- exigir volumen ni esperar el cierre de la vela.
   //--- directionOut: 1 = compra, -1 = venta, 0 = sin señal. Devuelve false si no hay señal.
   bool              Evaluate(CLevelRepository &repo, ENUM_TIMEFRAMES baseTf,
                               ENUM_TRADE_DIRECTION direction, double touchToleranceAtrMul, double atrBase,
                               bool requireConfirmation, CVolumeFilter &volFilter,
                               bool useRsiFilter, CRsiFilter &rsiFilter,
                               CTrendFilter &trendFilter, int trendSlopeBars, double trendThresholdAtrMul, double atrTrend,
                               CLevelCooldown &cooldown,
                               int &directionOut, double &triggeredLevelOut)
     {
      directionOut      = 0;
      triggeredLevelOut = 0.0;

      double open1 = 0.0, high1 = 0.0, low1 = 0.0, close1 = 0.0, bidNow = 0.0, askNow = 0.0, open0 = 0.0;
      if(requireConfirmation)
        {
         open1  = iOpen(_Symbol, baseTf, 1);
         high1  = iHigh(_Symbol, baseTf, 1);
         low1   = iLow(_Symbol, baseTf, 1);
         close1 = iClose(_Symbol, baseTf, 1);
         if(open1 <= 0.0 || high1 <= 0.0 || low1 <= 0.0 || close1 <= 0.0)
            return false;
        }
      else
        {
         //--- Cada lado se compara contra el precio al que realmente se ejecutaría esa
         //--- orden (OpenPosition compra a Ask y vende a Bid): así la línea dibujada
         //--- (lvl.price) queda a la distancia real de la entrada, sin el sesgo del spread.
         bidNow = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         askNow = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         open0  = iOpen(_Symbol, baseTf, 0);
         if(bidNow <= 0.0 || askNow <= 0.0 || open0 <= 0.0)
            return false;
        }

      bool allowBuy = false, allowSell = false;
      switch(direction)
        {
         case DIR_BUY_ONLY:
            allowBuy = true;
            break;
         case DIR_SELL_ONLY:
            allowSell = true;
            break;
         case DIR_BOTH:
            allowBuy  = true;
            allowSell = true;
            break;
         case DIR_TREND_FOLLOW:
           {
            int trendDir;
            if(!trendFilter.GetDirection(trendSlopeBars, trendThresholdAtrMul, atrTrend, trendDir))
               return false;
            allowBuy  = (trendDir == 1);
            allowSell = (trendDir == -1);
            break;
           }
        }

      if(!allowBuy && !allowSell)
         return false; // DIR_TREND_FOLLOW en mercado lateral: sin operaciones

      //--- Filtro de volumen (regla 1): obligatorio solo en modo confirmado. En modo
      //--- inmediato el usuario pidió explícitamente operar en el toque, sin esperar
      //--- confirmación de volumen ni de cierre de vela.
      if(requireConfirmation && !volFilter.IsVolumeConfirmed())
         return false;

      double touchFloor = touchToleranceAtrMul * atrBase;

      SLevel bestSell, bestBuy;
      ZeroMemory(bestSell);
      ZeroMemory(bestBuy);
      bool   haveSell = false, haveBuy = false;

      if(allowSell)
        {
         int n = repo.GetResistanceCount();
         for(int i = 0; i < n; i++) // ya ordenados por score ascendente: el primero que toca es el mejor
           {
            SLevel lvl;
            if(!repo.GetResistance(i, lvl))
               continue;
            double zoneTol = MathMax(touchFloor, lvl.sigma); // el nivel es una zona, no un punto
            if(cooldown.IsCoolingDown(lvl.price, zoneTol))
               continue; // nivel ya operado hace menos de InpLevelCooldownBars velas
            //--- Venta: OpenPosition ejecuta a Bid, igual que aquí.
            bool touched = requireConfirmation ? CheckResistanceTouch(lvl, open1, high1, close1, zoneTol)
                                                : CheckZoneTouchNow(lvl, bidNow, open0, zoneTol, false);
            if(touched)
              {
               bestSell = lvl;
               haveSell = true;
               break;
              }
           }
        }

      if(allowBuy)
        {
         int n = repo.GetSupportCount();
         for(int i = 0; i < n; i++)
           {
            SLevel lvl;
            if(!repo.GetSupport(i, lvl))
               continue;
            double zoneTol = MathMax(touchFloor, lvl.sigma);
            if(cooldown.IsCoolingDown(lvl.price, zoneTol))
               continue;
            //--- Compra: OpenPosition ejecuta a Ask, no a Bid; comparar contra Bid dejaba
            //--- la línea de soporte dibujada un spread por debajo del precio real de entrada.
            bool touched = requireConfirmation ? CheckSupportTouch(lvl, open1, low1, close1, zoneTol)
                                                : CheckZoneTouchNow(lvl, askNow, open0, zoneTol, true);
            if(touched)
              {
               bestBuy = lvl;
               haveBuy = true;
               break;
              }
           }
        }

      if(!haveSell && !haveBuy)
         return false;

      //--- Desempate: si ambos lados dispararon en la misma vela, gana el mejor puntaje
      int    candidateDirection;
      SLevel chosen;
      if(haveSell && haveBuy)
        {
         if(bestSell.score <= bestBuy.score)
           {
            candidateDirection = -1;
            chosen = bestSell;
           }
         else
           {
            candidateDirection = 1;
            chosen = bestBuy;
           }
        }
      else if(haveSell)
        {
         candidateDirection = -1;
         chosen = bestSell;
        }
      else
        {
         candidateDirection = 1;
         chosen = bestBuy;
        }

      //--- Filtro RSI direccional (regla 2 del estándar); no es parte de la estrategia
      //--- original, se incluye por defecto y es desactivable con InpUseRsiFilter.
      if(useRsiFilter && !rsiFilter.IsAllowed(candidateDirection))
         return false;

      directionOut      = candidateDirection;
      triggeredLevelOut = chosen.price;
      return true;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 14/17 - CRiskManager: break even + trailing stop
//==================================================================+

//+------------------------------------------------------------------+
//|                                                   RiskManager.mqh |
//|  CRiskManager: break even + trailing stop sobre la posición      |
//|  abierta, en ATR (regla 5/§4). Corre en cada tick (gestión de   |
//|  riesgo, no señal de entrada).                                   |
//+------------------------------------------------------------------+


class CRiskManager
  {
private:
   long              m_magicNumber;
   ENUM_TIMEFRAMES   m_baseTf;

   bool              m_useBreakEven;
   double            m_beTriggerAtrMul;
   double            m_beOffsetAtrMul;

   bool              m_useTrailing;
   double            m_trailingTriggerAtrMul;
   double            m_trailingAtrMul;
   double            m_trailingStepAtrMul;

   //--- true si el SL o TP VIGENTE está dentro de la zona de congelamiento del bróker:
   //--- en ese caso el servidor rechaza cualquier modificación (retcode 10029).
   bool              IsFrozen(double refPrice, double currentSL, double currentTP)
     {
      double freeze = GetFreezeDistance();
      if(freeze <= 0.0)
         return false;
      if(currentSL > 0.0 && MathAbs(refPrice - currentSL) <= freeze)
         return true;
      if(currentTP > 0.0 && MathAbs(refPrice - currentTP) <= freeze)
         return true;
      return false;
     }

   //--- Aplica break even y trailing a UNA posición ya seleccionada (vía SelectOwnPosition,
   //--- ver Manage()). Separado de Manage() para poder recorrer varias posiciones propias
   //--- simultáneas cuando InpMaxOpenPositions > 1: cada una se gestiona de forma
   //--- independiente, con su propio precio de apertura y su propio SL. Gatillo y
   //--- distancia de trailing desacoplados; el trailing solo mueve el SL cuando la mejora
   //--- supera el paso mínimo (m_trailingStepAtrMul), para no enviar un PositionModify
   //--- en cada tick favorable.
   void              ManageOne(CTrade &trade, ulong ticket, double atrValue)
     {
      bool   isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      double refPrice   = GetStopReferencePrice(isBuy);

      if(IsFrozen(refPrice, currentSL, currentTP))
         return;

      double profitDistance = isBuy ? (refPrice - openPrice) : (openPrice - refPrice);

      double newSL = currentSL;

      //--- Break even: asegura 'offset' de ganancia una vez alcanzado el trigger
      if(m_useBreakEven && m_beTriggerAtrMul > 0.0 && profitDistance >= m_beTriggerAtrMul * atrValue)
        {
         double offset    = m_beOffsetAtrMul * atrValue;
         double candidate = isBuy ? openPrice + offset : openPrice - offset;
         if(isBuy  && (currentSL <= 0.0 || candidate > newSL)) newSL = candidate;
         if(!isBuy && (currentSL <= 0.0 || candidate < newSL)) newSL = candidate;
        }

      //--- Trailing stop: sigue el precio a 'm_trailingAtrMul' de distancia, una vez que el
      //--- gatillo ('m_trailingTriggerAtrMul') se alcanzó. La mejora frente al SL VIGENTE
      //--- debe superar el paso mínimo; si no hay SL todavía, se coloca directamente.
      if(m_useTrailing && m_trailingTriggerAtrMul > 0.0 && m_trailingAtrMul > 0.0
         && profitDistance >= m_trailingTriggerAtrMul * atrValue)
        {
         double candidate = isBuy ? refPrice - m_trailingAtrMul * atrValue : refPrice + m_trailingAtrMul * atrValue;
         double step      = m_trailingStepAtrMul * atrValue;
         bool   stepOk    = (currentSL <= 0.0)
                            || (isBuy ? (candidate - currentSL >= step) : (currentSL - candidate >= step));
         if(stepOk && isBuy  && candidate > newSL) newSL = candidate;
         if(stepOk && !isBuy && (newSL <= 0.0 || candidate < newSL)) newSL = candidate;
        }

      if(newSL == currentSL)
         return;

      //--- El SL debe ir al tick del instrumento: un valor derivado de ATR casi nunca
      //--- es múltiplo de SYMBOL_TRADE_TICK_SIZE y el servidor lo rechazaría.
      newSL = NormalizePriceToTick(newSL);
      if(newSL == currentSL)
         return; // el redondeo lo dejó donde ya estaba: nada que modificar

      //--- Si el candidato queda más cerca del precio de lo que el bróker permite, se
      //--- omite este ajuste y se reintenta cuando el precio se aleje. Enviarlo igual
      //--- provocaría un PositionModify fallido en CADA tick durante toda la posición.
      if(!IsStopDistanceValid(isBuy, true, refPrice, newSL))
         return;

      //--- Por ticket, no por símbolo: con varias posiciones propias abiertas a la vez
      //--- (InpMaxOpenPositions > 1) en una cuenta de cobertura, PositionModify(symbol,...)
      //--- no identifica cuál de ellas modificar; el ticket sí.
      if(!trade.PositionModify(ticket, newSL, currentTP))
        {
         Print(__FUNCTION__, ": fallo al modificar SL de la posición #", ticket,
               ", retcode=", trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
        }
     }

public:
                     CRiskManager(void) : m_magicNumber(0),
                                           m_baseTf(PERIOD_CURRENT),
                                           m_useBreakEven(false),
                                           m_beTriggerAtrMul(0), m_beOffsetAtrMul(0),
                                           m_useTrailing(false),
                                           m_trailingTriggerAtrMul(0), m_trailingAtrMul(0),
                                           m_trailingStepAtrMul(0) {}

   void              Init(long magicNumber, ENUM_TIMEFRAMES baseTf,
                           bool useBreakEven, double beTriggerAtrMul, double beOffsetAtrMul,
                           bool useTrailing, double trailingTriggerAtrMul, double trailingAtrMul,
                           double trailingStepAtrMul)
     {
      m_magicNumber            = magicNumber;
      m_baseTf                 = baseTf;
      m_useBreakEven           = useBreakEven;
      m_beTriggerAtrMul        = beTriggerAtrMul;
      m_beOffsetAtrMul         = beOffsetAtrMul;
      m_useTrailing            = useTrailing;
      m_trailingTriggerAtrMul  = trailingTriggerAtrMul;
      m_trailingAtrMul         = trailingAtrMul;
      m_trailingStepAtrMul     = trailingStepAtrMul;
     }

   //--- Recorre break even y trailing sobre TODAS las posiciones propias (símbolo + magic)
   //--- abiertas a la vez. El ATR usado es el de la vela EN FORMACIÓN (shift 0) de la TF
   //--- base: a diferencia de la señal de entrada, esta gestión corre en cada tick, no solo
   //--- al cierre de vela; se lee una sola vez y se reutiliza para todas las posiciones.
   void              Manage(CTrade &trade, CAtrProvider &atr)
     {
      if(!m_useBreakEven && !m_useTrailing)
         return;

      if(!IsAutoTradingAllowed())
         return; // cualquier PositionModify fallaría; se reintenta cuando se habilite

      double atrValue = 0.0;
      //--- Un ATR no disponible no debe traducirse en distancia 0 (dispararía break even/
      //--- trailing de inmediato); se aborta la gestión de este tick y se reintenta en el
      //--- próximo, igual que TrendlineRebounder (if(atr <= 0.0) return;).
      if(!atr.GetValue(m_baseTf, 0, atrValue) || atrValue <= 0.0)
         return;

      //--- Recorrido por símbolo + magic, no PositionSelect(_Symbol): en cuenta de
      //--- cobertura puede haber varias posiciones propias a la vez (InpMaxOpenPositions > 1)
      //--- y también posiciones de otro EA o manuales que deben quedar fuera.
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = SelectOwnPosition(i, m_magicNumber);
         if(ticket != 0)
            ManageOne(trade, ticket, atrValue);
        }
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 15/17 - CPositionSizer: lotaje fijo vs % de riesgo
//==================================================================+

//+------------------------------------------------------------------+
//|                                                 PositionSizer.mqh |
//|  CPositionSizer: lotaje fijo o % de riesgo sobre el capital      |
//|  (mín. entre balance y equity), acotado por el tope de riesgo    |
//|  total de la cartera y normalizado a VOLUME_MIN/MAX/STEP.         |
//+------------------------------------------------------------------+


//--- Tolerancia para comparar/redondear volúmenes: 0.3/0.1 = 2.9999999... en punto
//--- flotante, y un MathFloor directo lo convertiría en 2 pasos en vez de 3.
#define SRMTF_VOLUME_EPSILON 1.0e-8

class CPositionSizer
  {
private:
   ENUM_LOT_MODE     m_mode;
   double            m_fixedLots;
   double            m_riskPercent;
   double            m_maxTotalRiskPercent;
   long              m_magicNumber;
   bool              m_verboseLog;

   double            GetLotStep(void)
     {
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      //--- lotStep en 0 (símbolo mal configurado) daría inf en la división y NaN al
      //--- multiplicar, y el NaN se propagaría hasta el volumen de la orden.
      if(lotStep <= 0.0)
         lotStep = minLot > 0.0 ? minLot : 0.01;
      return lotStep;
     }

   double            NormalizeLots(double lots)
     {
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = GetLotStep();
      int    digits  = (int)MathMax(0.0, MathCeil(-MathLog10(lotStep) - SRMTF_VOLUME_EPSILON));

      double normalized = NormalizeDouble(MathFloor(lots / lotStep + SRMTF_VOLUME_EPSILON) * lotStep, digits);
      return MathMax(minLot, MathMin(maxLot, normalized));
     }

public:
                     CPositionSizer(void) : m_mode(LOT_MODE_FIXED), m_fixedLots(0.10), m_riskPercent(1.0),
                                             m_maxTotalRiskPercent(0.0), m_magicNumber(0), m_verboseLog(false) {}

   void              Init(ENUM_LOT_MODE mode, double fixedLots, double riskPercent,
                           double maxTotalRiskPercent, long magicNumber, bool verboseLog)
     {
      m_mode                = mode;
      m_fixedLots           = fixedLots;
      m_riskPercent         = riskPercent;
      m_maxTotalRiskPercent = maxTotalRiskPercent;
      m_magicNumber         = magicNumber;
      m_verboseLog          = verboseLog;
     }

   //--- 'slPrice' = 0 significa "sin SL"; obligatorio en modo % de riesgo y con tope de
   //--- riesgo total activo (OnInit lo garantiza). Puede venir del SL por ATR o del SL
   //--- estructural — a CPositionSizer le da igual.
   //--- Los rechazos por condiciones de mercado (lote bajo el mínimo, presupuesto agotado)
   //--- se repiten en cada tick en modo inmediato, así que solo se loguean en verbose.
   bool              GetLots(bool isBuy, double entryPrice, double slPrice, double &lotsOut)
     {
      double capital = GetRiskCapital();
      if(capital <= 0.0)
        {
         Print(__FUNCTION__, ": capital de la cuenta no positivo (", DoubleToString(capital, 2), ")");
         return false;
        }

      double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double lossPerLot = 0.0;
      if(slPrice > 0.0 && !CalcStopLossMoney(isBuy, 1.0, entryPrice, slPrice, lossPerLot))
         return false;

      double rawLots = m_fixedLots;
      if(m_mode == LOT_MODE_RISK_PERCENT)
        {
         if(lossPerLot <= 0.0)
           {
            Print(__FUNCTION__, ": pérdida por lote no calculable (SL ausente o del lado de la ganancia)");
            return false;
           }

         rawLots = capital * (m_riskPercent / 100.0) / lossPerLot;

         //--- Si el lote que respeta el riesgo configurado es menor que el mínimo del
         //--- símbolo, NormalizeLots lo elevaría al mínimo y la operación arriesgaría
         //--- bastante más que InpRiskPercent, en silencio: se rechaza la entrada.
         if(rawLots + SRMTF_VOLUME_EPSILON < minLot)
           {
            if(m_verboseLog)
               Print(__FUNCTION__, ": lote requerido por riesgo (", DoubleToString(rawLots, 4),
                     ") menor que el mínimo del símbolo (", DoubleToString(minLot, 4),
                     "); riesgo real del lote mínimo: ", DoubleToString(minLot * lossPerLot, 2),
                     " sobre capital ", DoubleToString(capital, 2), "; se omite la operación");
            return false;
           }
        }

      //--- Tope de riesgo de la cartera: con varias posiciones simultáneas, el riesgo por
      //--- operación no acota la pérdida conjunta (50 x 5% = 250% del capital). Si la
      //--- nueva entrada excede el presupuesto restante, se reduce el lote hasta encajar;
      //--- si ni el lote mínimo cabe, se omite.
      if(m_maxTotalRiskPercent > 0.0)
        {
         if(lossPerLot <= 0.0)
           {
            Print(__FUNCTION__, ": el tope de riesgo total requiere una operación con SL");
            return false;
           }

         double openRisk;
         if(!GetOpenRiskMoney(m_magicNumber, openRisk))
           {
            if(m_verboseLog)
               Print(__FUNCTION__, ": hay una posición propia sin SL; su riesgo no es acotable ",
                     "y el tope de riesgo total no puede garantizarse: se omite la operación");
            return false;
           }

         double budget          = capital * (m_maxTotalRiskPercent / 100.0) - openRisk;
         double maxLotsByBudget = budget / lossPerLot;
         if(maxLotsByBudget + SRMTF_VOLUME_EPSILON < minLot)
           {
            if(m_verboseLog)
               Print(__FUNCTION__, ": presupuesto de riesgo total agotado (en riesgo ",
                     DoubleToString(openRisk, 2), " de un tope de ",
                     DoubleToString(capital * m_maxTotalRiskPercent / 100.0, 2), "); se omite la operación");
            return false;
           }
         rawLots = MathMin(rawLots, maxLotsByBudget);
        }

      lotsOut = NormalizeLots(rawLots);
      return (lotsOut > 0.0);
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 16/17 - CStructuralStop: SL estructural manual o por modelo
//==================================================================+

//+------------------------------------------------------------------+
//|                                               StructuralStop.mqh |
//|  CStructuralStop: precio del SL estructural (solo compra). Manual |
//|  (InpStructuralSLPrice) o calculado como el SL MÁS ALTO cuya      |
//|  probabilidad de ser tocado dentro del horizonte H no supera α.   |
//|                                                                  |
//|  Todo en escala logarítmica sobre la TF de análisis (W1 default). |
//|  P = cierre de la última vela cerrada, b = ln(P / SL) > 0:        |
//|                                                                  |
//|  1) Modelo: ln(precio) como browniano con deriva ν y volatilidad |
//|     σ por vela. Por el principio de reflexión, la probabilidad   |
//|     de que el mínimo de las próximas H velas toque P·e^(-b) es   |
//|       q_m(b) = Φ((-b-νH)/(σ√H)) + e^(-2νb/σ²)·Φ((-b+νH)/(σ√H))   |
//|     σ = máx(σ de toda la ventana, σ reciente): una catástrofe no |
//|     se mide asumiendo el más calmo de los dos regímenes.          |
//|     ν = κ·máx(0, ν̂): la deriva histórica es la estimación más   |
//|     ruidosa y la que más acerca el SL, por eso se encoge.        |
//|  2) Empírico: q_e(b) = fracción de velas históricas desde cuyo   |
//|     cierre el mínimo (Low) de las H velas siguientes cayó b o    |
//|     más. Cubre colas gordas y caídas en racha que el browniano   |
//|     subestima.                                                   |
//|  q(b) = máx(q_m, q_e) es no creciente en b; b* = mín{b: q(b) ≤ α}|
//|  por bisección, y SL = P·e^(-b*).                                |
//|                                                                  |
//|  Por qué el borde q(b*) = α es el óptimo rendimiento/riesgo: en  |
//|  modo % de riesgo la exposición es R/d, con d = 1 - e^(-b).      |
//|  Alejar el SL baja la exposición (rendimiento) y la probabilidad |
//|  de tocarlo (riesgo), ambas en forma monótona: el SL que         |
//|  maximiza la exposición sujeto a "solo una catástrofe lo toca"   |
//|  (q ≤ α) es el borde. Un Kelly sin esa restricción lo ubicaría   |
//|  mucho más cerca (q de 40-50% con riesgos de 10%): dejaría de    |
//|  ser un SL de catástrofe, por eso manda la restricción.          |
//+------------------------------------------------------------------+

//--- Ventanas de H velas mínimas para que la frecuencia empírica signifique algo
#define SRMTF_STRUCT_SL_MIN_WINDOWS  52
//--- Tope de búsqueda de b: ln(1000), es decir, un SL hasta 99.9% bajo la referencia
#define SRMTF_STRUCT_SL_MAX_LOG_DIST 6.9
//--- Precisión de la bisección en b (≈ 0.0001% del precio)
#define SRMTF_STRUCT_SL_LOG_TOL      1.0e-6

//+------------------------------------------------------------------+
//| Φ(x), CDF normal estándar, vía erfc de Chebyshev (Numerical       |
//| Recipes, error RELATIVO < 1.2e-7): α vive en la cola, donde un    |
//| error absoluto pequeño ya es un error relativo grande.            |
//+------------------------------------------------------------------+
double NormalCdf(double x)
  {
   double z     = MathAbs(x) / M_SQRT2;
   double t     = 1.0 / (1.0 + 0.5 * z);
   double erfcZ = t * MathExp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418
                  + t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587
                  + t * (-0.82215223 + t * 0.17087277)))))))));
   return (x >= 0.0) ? 1.0 - 0.5 * erfcZ : 0.5 * erfcZ;
  }

class CStructuralStop
  {
private:
   ENUM_STRUCT_SL_MODE m_mode;
   double            m_manualPrice;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_lookbackBars;
   int               m_horizonBars;
   int               m_recentVolBars;
   double            m_maxTouchProb;     // α como fracción (el input viene en %)
   double            m_driftWeight;      // κ
   bool              m_verboseLog;

   CBarMonitor       m_barMonitor;

   //--- Último ajuste exitoso sobre la TF de análisis
   bool              m_fitted;
   int               m_barsUsed;
   double            m_referencePrice;   // P
   double            m_sigma;            // σ por vela, ya estresada
   double            m_rawDrift;         // ν̂ por vela, sin encoger (solo para el log)
   double            m_drift;            // ν por vela usada por el modelo
   double            m_excursions[];     // caída logarítmica máxima en H velas desde cada cierre, ascendente

   bool              m_hasAutoPrice;
   double            m_autoPrice;

   int               MinBarsRequired(void) const
     {
      return MathMax(m_horizonBars + SRMTF_STRUCT_SL_MIN_WINDOWS, m_recentVolBars + 1);
     }

   double            BarsPerYear(void) const
     {
      return 365.25 * 86400.0 / PeriodSeconds(m_timeframe);
     }

   //--- Ajusta σ, ν y la distribución empírica de caídas usando solo velas CERRADAS de
   //--- la TF de análisis (shift ≥ 1): sin la vela en formación no hay sesgo de
   //--- anticipación en el Probador.
   bool              Fit(bool logFailures)
     {
      m_fitted = false;

      int available = Bars(_Symbol, m_timeframe) - 1;
      int count     = MathMin(m_lookbackBars, available);
      if(count < MinBarsRequired())
        {
         if(logFailures)
            Print(__FUNCTION__, ": historial insuficiente en ", TimeframeShortName(m_timeframe), " (",
                  MathMax(available, 0), " velas cerradas; se necesitan ", MinBarsRequired(), ")");
         return false;
        }

      //--- Sin ArraySetAsSeries: [0] = vela más antigua, en orden cronológico
      double closes[], lows[];
      if(CopyClose(_Symbol, m_timeframe, 1, count, closes) != count
         || CopyLow(_Symbol, m_timeframe, 1, count, lows) != count)
        {
         if(logFailures)
            Print(__FUNCTION__, ": error copiando ", count, " velas de ", TimeframeShortName(m_timeframe),
                  ", code=", GetLastError());
         return false;
        }

      int    returnsCount = count - 1;
      int    recentStart  = returnsCount - m_recentVolBars;
      double sum = 0.0, sumSq = 0.0, recentSum = 0.0, recentSumSq = 0.0;
      for(int i = 1; i < count; i++)
        {
         if(closes[i - 1] <= 0.0 || closes[i] <= 0.0)
           {
            Print(__FUNCTION__, ": cierre no positivo en el historial de ", TimeframeShortName(m_timeframe));
            return false;
           }
         double r = MathLog(closes[i] / closes[i - 1]);
         sum   += r;
         sumSq += r * r;
         if(i - 1 >= recentStart)
           {
            recentSum   += r;
            recentSumSq += r * r;
           }
        }

      double mean       = sum / returnsCount;
      double varLong    = (sumSq - returnsCount * mean * mean) / (returnsCount - 1);
      double recentMean = recentSum / m_recentVolBars;
      double varRecent  = (recentSumSq - m_recentVolBars * recentMean * recentMean) / (m_recentVolBars - 1);
      double sigma      = MathSqrt(MathMax(0.0, MathMax(varLong, varRecent)));
      if(sigma <= 0.0)
        {
         Print(__FUNCTION__, ": volatilidad nula en ", TimeframeShortName(m_timeframe), "; no hay modelo que ajustar");
         return false;
        }

      int windows = count - m_horizonBars;
      if(ArrayResize(m_excursions, windows) != windows)
        {
         Print(__FUNCTION__, ": no se pudo reservar memoria para ", windows, " ventanas");
         return false;
        }
      for(int i = 0; i < windows; i++)
        {
         double minLow = lows[i + 1];
         for(int j = i + 2; j <= i + m_horizonBars; j++)
            minLow = MathMin(minLow, lows[j]);
         if(minLow <= 0.0)
           {
            Print(__FUNCTION__, ": mínimo no positivo en el historial de ", TimeframeShortName(m_timeframe));
            return false;
           }
         m_excursions[i] = MathLog(closes[i] / minLow);
        }
      ArraySort(m_excursions);

      m_barsUsed       = count;
      m_referencePrice = closes[count - 1];
      m_sigma          = sigma;
      m_rawDrift       = mean;
      m_drift          = m_driftWeight * MathMax(0.0, mean);
      m_fitted         = true;
      return true;
     }

   double            ModelTouchProb(double b) const
     {
      double s   = m_sigma * MathSqrt((double)m_horizonBars);
      double nuH = m_drift * m_horizonBars;
      return NormalCdf((-b - nuH) / s)
             + MathExp(-2.0 * m_drift * b / (m_sigma * m_sigma)) * NormalCdf((-b + nuH) / s);
     }

   double            EmpiricalTouchProb(double b) const
     {
      int n  = ArraySize(m_excursions);
      int lo = 0, hi = n;
      while(lo < hi) // primera excursión ≥ b en el array ascendente
        {
         int mid = (lo + hi) / 2;
         if(m_excursions[mid] < b)
            lo = mid + 1;
         else
            hi = mid;
        }
      return (double)(n - lo) / n;
     }

   double            TouchProb(double b) const
     {
      return MathMax(ModelTouchProb(b), EmpiricalTouchProb(b));
     }

   //--- b* = mín{b : q(b) ≤ alpha}. false si ni un SL a -99.9% cumple (activo demasiado
   //--- volátil para ese α): no existe un SL de catástrofe razonable.
   bool              SolveLogDistance(double alpha, double &bOut) const
     {
      if(TouchProb(SRMTF_STRUCT_SL_MAX_LOG_DIST) > alpha)
         return false;

      double lo = 0.0, hi = SRMTF_STRUCT_SL_MAX_LOG_DIST;
      while(hi - lo > SRMTF_STRUCT_SL_LOG_TOL)
        {
         double mid = 0.5 * (lo + hi);
         if(TouchProb(mid) > alpha)
            lo = mid;
         else
            hi = mid;
        }
      bOut = hi;
      return true;
     }

   string            Pct(double fraction) const
     {
      return DoubleToString(100.0 * fraction, 2) + "%";
     }

   string            FitSummary(void) const
     {
      double barsPerYear = BarsPerYear();
      return StringFormat("σ anual=%.2f, ν̂ anual=%.2f (usada %.2f, κ=%.2f), %d velas %s",
                          m_sigma * MathSqrt(barsPerYear), m_rawDrift * barsPerYear, m_drift * barsPerYear,
                          m_driftWeight, m_barsUsed, TimeframeShortName(m_timeframe));
     }

   void              ComputeAutoPrice(void)
     {
      double b;
      if(!SolveLogDistance(m_maxTouchProb, b))
        {
         m_hasAutoPrice = false;
         Print("SRMTF | SL estructural automático: ni a -99.9% la probabilidad de toque baja de α=",
               Pct(m_maxTouchProb), " (", FitSummary(), "); no se abrirán compras hasta el próximo recálculo");
         return;
        }

      m_autoPrice    = NormalizePriceToTick(m_referencePrice * MathExp(-b));
      m_hasAutoPrice = (m_autoPrice > 0.0);

      double drop = 1.0 - MathExp(-b);
      Print("SRMTF | SL estructural automático: ", DoubleToString(m_autoPrice, _Digits),
            " (-", DoubleToString(100.0 * drop, 1), "% desde el cierre ", DoubleToString(m_referencePrice, _Digits),
            ") | P(toque en ", m_horizonBars, " velas): modelo ", Pct(ModelTouchProb(b)),
            ", empírica ", Pct(EmpiricalTouchProb(b)), ", α=", Pct(m_maxTouchProb),
            " | exposición por cada 1% de capital en riesgo: ", DoubleToString(1.0 / drop, 2), "% | ", FitSummary());
     }

   //--- En modo manual el modelo no decide nada: solo informa qué tan "de catástrofe" es
   //--- el precio elegido a mano, para que el usuario no fije un SL alto sin saberlo.
   void              LogManualDiagnostics(void) const
     {
      if(m_manualPrice >= m_referencePrice)
        {
         Print("SRMTF | SL estructural manual ", DoubleToString(m_manualPrice, _Digits),
               " por encima o igual al cierre de referencia ", DoubleToString(m_referencePrice, _Digits),
               ": toda compra por debajo de ese precio se omitirá");
         return;
        }

      double b = MathLog(m_referencePrice / m_manualPrice);
      double bSuggested;
      string suggested = SolveLogDistance(m_maxTouchProb, bSuggested)
                         ? DoubleToString(NormalizePriceToTick(m_referencePrice * MathExp(-bSuggested)), _Digits)
                         : "sin solución";

      Print("SRMTF | SL estructural manual ", DoubleToString(m_manualPrice, _Digits),
            " (-", DoubleToString(100.0 * (1.0 - MathExp(-b)), 1), "% desde el cierre ",
            DoubleToString(m_referencePrice, _Digits), ") | P(toque en ", m_horizonBars, " velas): modelo ",
            Pct(ModelTouchProb(b)), ", empírica ", Pct(EmpiricalTouchProb(b)),
            " | sugerido por el modelo para α=", Pct(m_maxTouchProb), ": ", suggested, " | ", FitSummary());
     }

   //--- Curva riesgo/rendimiento completa alrededor del α elegido, para decidir α con datos
   void              LogFrontier(void) const
     {
      double alphas[] = {0.01, 0.02, 0.05, 0.10, 0.20};
      Print("SRMTF | Frontera del SL estructural (α → SL, caída, exposición por cada 1% de capital en riesgo):");
      for(int i = 0; i < ArraySize(alphas); i++)
        {
         double b;
         if(!SolveLogDistance(alphas[i], b))
           {
            Print("  α=", Pct(alphas[i]), " → sin solución");
            continue;
           }
         double drop = 1.0 - MathExp(-b);
         Print("  α=", Pct(alphas[i]), " → SL=", DoubleToString(NormalizePriceToTick(m_referencePrice * MathExp(-b)), _Digits),
               " (-", DoubleToString(100.0 * drop, 1), "%), exposición=", DoubleToString(1.0 / drop, 2), "%");
        }
     }

public:
                     CStructuralStop(void) : m_mode(STRUCT_SL_MANUAL), m_manualPrice(0.0),
                                              m_timeframe(PERIOD_W1), m_lookbackBars(0), m_horizonBars(0),
                                              m_recentVolBars(0), m_maxTouchProb(0.0), m_driftWeight(0.0),
                                              m_verboseLog(false), m_fitted(false), m_barsUsed(0),
                                              m_referencePrice(0.0), m_sigma(0.0), m_rawDrift(0.0), m_drift(0.0),
                                              m_hasAutoPrice(false), m_autoPrice(0.0) {}

   //--- Los parámetros del modelo se validan también en modo manual: ahí alimentan el
   //--- diagnóstico del precio elegido a mano.
   bool              Init(ENUM_STRUCT_SL_MODE mode, double manualPrice, ENUM_TIMEFRAMES timeframe,
                          int lookbackBars, int horizonBars, int recentVolBars,
                          double maxTouchProbPct, double driftWeight, bool verboseLog)
     {
      m_mode          = mode;
      m_manualPrice   = manualPrice;
      m_timeframe     = timeframe;
      m_lookbackBars  = lookbackBars;
      m_horizonBars   = horizonBars;
      m_recentVolBars = recentVolBars;
      m_maxTouchProb  = maxTouchProbPct / 100.0;
      m_driftWeight   = driftWeight;
      m_verboseLog    = verboseLog;
      m_fitted        = false;
      m_hasAutoPrice  = false;

      if(m_mode == STRUCT_SL_MANUAL && m_manualPrice <= 0.0)
        {
         Print(__FUNCTION__, ": InpStructuralSLPrice debe ser mayor que 0 en modo manual");
         return false;
        }
      if(m_horizonBars < 1 || m_recentVolBars < 2)
        {
         Print(__FUNCTION__, ": InpStructSlHorizonBars debe ser >= 1 e InpStructSlRecentVolBars >= 2");
         return false;
        }
      if(maxTouchProbPct <= 0.0 || maxTouchProbPct >= 100.0)
        {
         Print(__FUNCTION__, ": InpStructSlMaxTouchProb debe estar entre 0 y 100 (exclusivo)");
         return false;
        }
      if(m_driftWeight < 0.0 || m_driftWeight > 1.0)
        {
         Print(__FUNCTION__, ": InpStructSlDriftWeight debe estar entre 0 y 1");
         return false;
        }
      if(m_lookbackBars < MinBarsRequired())
        {
         Print(__FUNCTION__, ": InpStructSlLookbackBars (", m_lookbackBars, ") debe ser al menos ",
               MinBarsRequired(), " (horizonte + ", SRMTF_STRUCT_SL_MIN_WINDOWS,
               " ventanas para la frecuencia empírica)");
         return false;
        }

      m_barMonitor.Init(m_timeframe);
      return true;
     }

   //--- Recalcula una vez por vela nueva de la TF de análisis. Si el historial aún no está
   //--- disponible (MT5 lo descarga en forma asíncrona), reintenta en cada vela nueva de la
   //--- TF base, informando el fallo solo en vela de análisis para no inundar el log. Si un
   //--- recálculo falla, el último SL automático válido se conserva: un nivel estructural
   //--- semanal sigue siendo razonable mientras se recupera el historial.
   void              Update(bool isNewBaseBar)
     {
      bool isNewAnalysisBar = m_barMonitor.IsNewBar();
      if(!isNewAnalysisBar && !(isNewBaseBar && !m_fitted))
         return;

      if(!Fit(isNewAnalysisBar || m_verboseLog))
         return;

      if(m_mode == STRUCT_SL_AUTO)
         ComputeAutoPrice();
      else
         LogManualDiagnostics();

      if(m_verboseLog)
         LogFrontier();
     }

   //--- Precio vigente del SL estructural. false en modo automático mientras no haya un
   //--- cálculo válido: sin SL no hay base para dimensionar ni acotar el riesgo.
   bool              GetPrice(double &priceOut) const
     {
      if(m_mode == STRUCT_SL_MANUAL)
        {
         priceOut = m_manualPrice;
         return true;
        }
      if(!m_hasAutoPrice)
         return false;
      priceOut = m_autoPrice;
      return true;
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| SECCION 17/17 - CLevelRenderer: dibujo de niveles
//==================================================================+

//+------------------------------------------------------------------+
//|                                                 LevelRenderer.mqh |
//|  CLevelRenderer: dibuja los niveles seleccionados en el gráfico. |
//|  Hito de validación visual de la estrategia (ver PLAN.md §6/§8). |
//|  Todos los objetos llevan prefijo SRMTF_ y se limpian por        |
//|  completo antes de cada redibujo y en OnDeinit.                   |
//+------------------------------------------------------------------+


#define SRMTF_OBJ_PREFIX "SRMTF_"

class CLevelRenderer
  {
private:
   bool              m_drawLevels;
   color             m_colorSupport;
   color             m_colorResistance;

   void              DrawOneLevel(const SLevel &lvl, int rankWithinSide, color clr)
     {
      string tag  = lvl.isResistance ? "R" : "S";
      string base = SRMTF_OBJ_PREFIX + tag + IntegerToString(rankWithinSide);

      string lineName = base + "_line";
      if(ObjectFind(0, lineName) < 0)
         ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, lvl.price);
      else
         ObjectSetDouble(0, lineName, OBJPROP_PRICE, lvl.price);

      ObjectSetInteger(0, lineName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DASH); // "--" en vez de línea sólida
      //--- grosor proporcional al ranking: el mejor nivel del lado (rank 0) se dibuja más grueso
      int width = MathMax(1, 4 - rankWithinSide);
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, lineName, OBJPROP_BACK, true);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);

      //--- "Toques-Temporalidades-Puntaje" ya no se dibuja siempre visible en el gráfico:
      //--- se deja como tooltip de la propia línea (OBJPROP_TOOLTIP), visible solo al
      //--- pasar el mouse por encima. Se omite si es soporte o resistencia porque ya es
      //--- obvio por el color y la posición de la línea respecto al precio. La temporalidad
      //--- usa tfMask (no lvl.timeframe): tras la fusión por confluencia, tfMask lista TODAS
      //--- las TFs que aportaron a esta línea (p.ej. "M15+H1+H4"), mientras que lvl.timeframe
      //--- solo guarda una referencia informativa del primer candidato fusionado — engañoso
      //--- aquí. Toques usa el conteo ENTERO de velas distintas (lvl.touchCandles), no el
      //--- N_eff ponderado que usa el puntaje internamente — pensado para un usuario que no
      //--- conoce el algoritmo: "8 velas tocaron esta zona" se lee sin explicación.
      string tooltip = StringFormat("Precio: %s, Toques: %d, Temporalidad: %s, Puntaje: %.4f",
                                     DoubleToString(lvl.price, _Digits), lvl.touchCandles,
                                     TfMaskToLabel(lvl.tfMask), lvl.score);
      ObjectSetString(0, lineName, OBJPROP_TOOLTIP, tooltip);
     }

public:
                     CLevelRenderer(void) : m_drawLevels(true),
                                             m_colorSupport(clrLimeGreen), m_colorResistance(clrTomato) {}

   void              Init(bool drawLevels, color colorSupport, color colorResistance)
     {
      m_drawLevels      = drawLevels;
      m_colorSupport    = colorSupport;
      m_colorResistance = colorResistance;
     }

   void              Clear(void)
     {
      ObjectsDeleteAll(0, SRMTF_OBJ_PREFIX);
     }

   void              Redraw(SLevel &resistances[], SLevel &supports[])
     {
      Clear();
      if(!m_drawLevels)
         return;

      int resCount = ArraySize(resistances);
      for(int i = 0; i < resCount; i++)
         DrawOneLevel(resistances[i], i, m_colorResistance);

      int supCount = ArraySize(supports);
      for(int i = 0; i < supCount; i++)
         DrawOneLevel(supports[i], i, m_colorSupport);

      ChartRedraw(0);
     }

   void              Deinit(void)
     {
      Clear();
      ChartRedraw(0);
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| ORQUESTADOR - SExpertConfig + CExpertAdvisor
//==================================================================+

//+------------------------------------------------------------------+
//|                                                       Expert.mqh |
//|  CExpertAdvisor: orquesta el motor de niveles S/R multi-TF, los  |
//|  filtros obligatorios, la gestión de riesgo ATR/precio y CTrade.|
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| SExpertConfig: agrupa TODOS los inputs del .mq5 en un solo       |
//| struct. Con ~50 parámetros, una lista plana en Init() sería      |
//| inmanejable; el struct se arma una vez en OnInit desde los       |
//| inputs y se pasa por referencia.                                  |
//+------------------------------------------------------------------+
struct SExpertConfig
  {
   //--- General
   long                  magicNumber;
   int                   slippage;
   ENUM_TIMEFRAMES       baseTimeframe;  // PERIOD_CURRENT se resuelve a _Period antes de llegar aquí
   bool                  verboseLog;
   bool                  requireConfirmation;  // false = operar en el toque, sin esperar volumen/cierre de vela
   int                   maxOpenPositions;     // máximo de posiciones propias (symbol+magic) abiertas a la vez
   double                minEntryDistanceAtrMul; // distancia mínima (x ATR base) frente a otra posición propia ya abierta (0 = sin mínimo)
   double                maxSpreadAtrMul;        // spread máximo (x ATR base) para abrir (0 = sin filtro)

   //--- Detección de niveles / Clustering (KDE)
   int                   barsToAnalyze;
   int                   minTouches;
   double                kdeBandwidthAtrMul;
   int                   kdeGridNodes;
   double                minDensityRatio;
   double                zoneWidthAtrMul;

   //--- Puntaje
   double                relevanceRangeAtrMul;
   double                minWeight;
   double                distPenaltyLambda;
   double                touchExponent;
   double                minSigmaAtr;
   double                timeDecayHalfLife;

   //--- Multi-temporalidad (el abanico M5..D1 estrictamente superior a la base
   //--- siempre se analiza por completo; no hay toggles por TF)
   double                tfExponent;
   double                mergeToleranceAtrMul;
   double                confluenceBonus;

   //--- Selección de líneas
   int                   maxLinesAbove;
   int                   maxLinesBelow;
   double                minSeparationAtrMul;

   //--- Señal
   ENUM_TRADE_DIRECTION  direction;
   double                touchToleranceAtrMul;
   int                   levelCooldownBars;

   //--- Filtro de tendencia
   ENUM_TIMEFRAMES       trendTimeframe;
   int                   trendEmaPeriod;
   int                   trendSlopeBars;
   double                trendThresholdAtrMul;

   //--- Filtro de volumen
   int                   volumePeriod;
   bool                  useRealVolumeIfAvailable;

   //--- Filtro RSI
   bool                  useRsiFilter;
   int                   rsiPeriod;
   double                rsiOverbought;
   double                rsiOversold;

   //--- ATR
   int                   atrPeriod;

   //--- Stop Loss / Take Profit
   bool                  useSl;
   double                slAtrMul;
   bool                  useTp;
   double                tpAtrMul;

   //--- Stop Loss estructural
   bool                  useStructuralSl;
   ENUM_STRUCT_SL_MODE   structuralSlMode;
   double                structuralSlPrice;           // solo modo manual
   ENUM_TIMEFRAMES       structuralSlTimeframe;       // PERIOD_CURRENT ya resuelto
   int                   structuralSlLookbackBars;
   int                   structuralSlHorizonBars;
   double                structuralSlMaxTouchProbPct; // α en %
   double                structuralSlDriftWeight;     // κ
   int                   structuralSlRecentVolBars;

   //--- Take Profit estructural
   bool                  useStructuralTp;

   //--- Break Even
   bool                  useBreakEven;
   double                beTriggerAtrMul;
   double                beOffsetAtrMul;

   //--- Trailing Stop
   bool                  useTrailing;
   double                trailingTriggerAtrMul;
   double                trailingAtrMul;
   double                trailingStepAtrMul;

   //--- Lotaje
   ENUM_LOT_MODE         lotMode;
   double                fixedLots;
   double                riskPercent;
   double                maxTotalRiskPercent;

   //--- Visualización
   bool                  drawLevels;
   color                 colorSupport;
   color                 colorResistance;
  };

//+------------------------------------------------------------------+
//| CExpertAdvisor                                                    |
//+------------------------------------------------------------------+
class CExpertAdvisor
  {
private:
   CTrade            m_trade;
   CBarMonitor       m_baseBarMonitor;
   CAtrProvider      m_atr;
   CLevelRepository  m_repo;
   CLevelRenderer    m_renderer;
   CSignalEngine     m_signalEngine;
   CVolumeFilter     m_volFilter;
   CRsiFilter        m_rsiFilter;
   CTrendFilter      m_trendFilter;
   CRiskManager      m_riskManager;
   CPositionSizer    m_sizer;
   CLevelCooldown    m_cooldown;
   CStructuralStop   m_structuralStop;

   SExpertConfig     m_cfg;

   //--- true una vez que RecomputeLevels() produjo una selección válida al menos una
   //--- vez; en modo inmediato (requireConfirmation = false) habilita evaluar el toque
   //--- en cada tick sin repetir el recálculo de niveles, que solo cambia en vela nueva.
   bool              m_levelsReady;

   //--- Vuelca a Print() los niveles seleccionados y las componentes de su puntaje.
   //--- Simplificación consciente respecto al plan (§6): audita el resultado final
   //--- de la selección, no cada candidato de cada TF antes de fusionar/filtrar.
   void              LogSelectedLevels(void)
     {
      SLevel res[], sup[];
      m_repo.GetResistances(res);
      m_repo.GetSupports(sup);

      Print("SRMTF | Resistencias seleccionadas: ", ArraySize(res));
      for(int i = 0; i < ArraySize(res); i++)
         Print("  R", i, " price=", DoubleToString(res[i].price, _Digits),
               " score=", DoubleToString(res[i].score, 5),
               " toques_efectivos=", DoubleToString(res[i].effTouches, 2),
               " confluencia=", res[i].confluence, " (", TfMaskToLabel(res[i].tfMask), ")");

      Print("SRMTF | Soportes seleccionados: ", ArraySize(sup));
      for(int i = 0; i < ArraySize(sup); i++)
         Print("  S", i, " price=", DoubleToString(sup[i].price, _Digits),
               " score=", DoubleToString(sup[i].score, 5),
               " toques_efectivos=", DoubleToString(sup[i].effTouches, 2),
               " confluencia=", sup[i].confluence, " (", TfMaskToLabel(sup[i].tfMask), ")");
     }

   //--- Nivel opuesto más cercano al precio actual (resistencia para compra, soporte
   //--- para venta), usado como Take Profit estructural (InpUseStructuralTP). No exige
   //--- que la entrada haya tocado ESE nivel: toma el mejor candidato ya seleccionado
   //--- por CLevelRepository en el último recálculo (el de menor distancia al precio).
   //--- false si no hay ningún nivel de ese lado seleccionado en este momento.
   bool              GetOppositeLevelPrice(bool isBuy, double &priceOut)
     {
      bool   found = false;
      double best  = 0.0;

      if(isBuy)
        {
         int n = m_repo.GetResistanceCount();
         for(int i = 0; i < n; i++)
           {
            SLevel lvl;
            if(!m_repo.GetResistance(i, lvl))
               continue;
            if(!found || lvl.price < best) // la resistencia MÁS CERCANA es la de menor precio
              {
               best  = lvl.price;
               found = true;
              }
           }
        }
      else
        {
         int n = m_repo.GetSupportCount();
         for(int i = 0; i < n; i++)
           {
            SLevel lvl;
            if(!m_repo.GetSupport(i, lvl))
               continue;
            if(!found || lvl.price > best) // el soporte MÁS CERCANO es el de mayor precio
              {
               best  = lvl.price;
               found = true;
              }
           }
        }

      if(!found)
         return false;

      priceOut = best;
      return true;
     }

   //--- true si 'candidatePrice' respeta InpMinEntryDistanceAtr frente a TODAS las
   //--- posiciones propias (symbol+magic) ya abiertas. Con InpMaxOpenPositions > 1, el
   //--- único freno para entradas repetidas era el cupo (CountOwnPositions): en modo
   //--- "al toque" (InpRequireConfirmation = false), si el precio queda pegado dentro de
   //--- la tolerancia del nivel varios ticks seguidos, el EA llenaba el cupo casi al mismo
   //--- precio (ver incidente: 18 compras en 20 segundos dentro de un rango de 50 puntos).
   //--- 'minDistance' <= 0 desactiva el chequeo.
   bool              IsFarEnoughFromOwnPositions(double candidatePrice, double minDistance)
     {
      if(minDistance <= 0.0)
         return true;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(SelectOwnPosition(i, m_cfg.magicNumber) == 0)
            continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         if(MathAbs(candidatePrice - openPrice) < minDistance)
            return false;
        }

      return true;
     }

   //--- Margen libre suficiente para 'lots'. Con varias posiciones abiertas, enviar la
   //--- orden sin verificarlo termina en retcode 10019 (fondos insuficientes) repetido.
   bool              HasFreeMarginFor(bool isBuy, double lots, double price)
     {
      double margin = 0.0;
      if(!OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, margin))
        {
         Print(__FUNCTION__, ": OrderCalcMargin falló, code=", GetLastError());
         return false;
        }
      return margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE);
     }

   bool              OpenPosition(int direction, double triggeredLevel)
     {
      bool   isBuy = (direction == 1);

      if(!IsSymbolOpenAllowed(isBuy))
        {
         if(m_cfg.verboseLog)
            Print(__FUNCTION__, ": el símbolo no admite abrir ", (isBuy ? "compras" : "ventas"),
                  " en este momento (modo de trading del símbolo); se omite la operación");
         return false;
        }

      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      //--- ATR de la última vela cerrada, coherente con la señal evaluada solo al cierre de vela
      double atrValue;
      if(!m_atr.GetValue(m_cfg.baseTimeframe, 1, atrValue) || atrValue <= 0.0)
         return false;

      double minEntryDistance = m_cfg.minEntryDistanceAtrMul * atrValue;
      if(!IsFarEnoughFromOwnPositions(price, minEntryDistance))
        {
         //--- En modo inmediato esta rama se re-evalúa en cada tick mientras el precio
         //--- siga dentro de la zona de un nivel: sin este gate, un Print() incondicional
         //--- aquí inunda la pestaña "Expertos" con el mismo mensaje decenas de veces por
         //--- segundo. Se deja disponible bajo InpVerboseLog para quien quiera auditarlo.
         if(m_cfg.verboseLog)
            Print(__FUNCTION__, ": precio de entrada (", DoubleToString(price, _Digits),
                  ") a menos de ", DoubleToString(minEntryDistance, _Digits),
                  " de una posición propia ya abierta; se omite la operación");
         return false;
        }

      double sl    = 0.0;
      bool   hasSl = false;

      //--- El SL estructural solo aplica en compra: OnInit exige DIR_BUY_ONLY cuando está activo
      if(m_cfg.useStructuralSl && isBuy)
        {
         double structuralSl;
         if(!m_structuralStop.GetPrice(structuralSl))
           {
            if(m_cfg.verboseLog)
               Print(__FUNCTION__, ": SL estructural automático aún no disponible; se omite la operación");
            return false;
           }
         if(structuralSl >= price)
           {
            if(m_cfg.verboseLog)
               Print(__FUNCTION__, ": SL estructural (", DoubleToString(structuralSl, _Digits),
                     ") por encima o igual al precio de entrada (", DoubleToString(price, _Digits),
                     "); se omite la operación");
            return false;
           }
         sl    = structuralSl;
         hasSl = true;
        }
      else if(m_cfg.useSl)
        {
         double dist = m_cfg.slAtrMul * atrValue;
         sl    = isBuy ? price - dist : price + dist;
         hasSl = true;
        }

      double tp    = 0.0;
      bool   hasTp = false;

      //--- TP estructural: usa el nivel opuesto ya seleccionado (resistencia en compra,
      //--- soporte en venta) en vez de una distancia fija en ATR.
      if(m_cfg.useStructuralTp)
        {
         double levelPrice;
         if(!GetOppositeLevelPrice(isBuy, levelPrice))
           {
            if(m_cfg.verboseLog)
               Print(__FUNCTION__, ": no hay ningún nivel de ", (isBuy ? "resistencia" : "soporte"),
                     " seleccionado para el TP estructural; se omite la operación");
            return false;
           }
         if(isBuy && levelPrice <= price)
           {
            if(m_cfg.verboseLog)
               Print(__FUNCTION__, ": TP estructural (", DoubleToString(levelPrice, _Digits),
                     ") por debajo o igual al precio de entrada (", DoubleToString(price, _Digits),
                     "); se omite la operación");
            return false;
           }
         if(!isBuy && levelPrice >= price)
           {
            if(m_cfg.verboseLog)
               Print(__FUNCTION__, ": TP estructural (", DoubleToString(levelPrice, _Digits),
                     ") por encima o igual al precio de entrada (", DoubleToString(price, _Digits),
                     "); se omite la operación");
            return false;
           }
         tp    = levelPrice;
         hasTp = true;
        }
      else if(m_cfg.useTp)
        {
         double dist = m_cfg.tpAtrMul * atrValue;
         tp    = isBuy ? price + dist : price - dist;
         hasTp = true;
        }

      //--- Los niveles derivados de ATR casi nunca caen en un múltiplo del tick del
      //--- instrumento; CTrade no los normaliza, así que el servidor los rechazaría
      //--- con TRADE_RETCODE_INVALID_STOPS. El TP estructural sí puede necesitarlo: un
      //--- nivel WLS tampoco cae necesariamente en un múltiplo exacto del tick.
      if(hasSl)
         sl = NormalizePriceToTick(sl);
      if(hasTp)
         tp = NormalizePriceToTick(tp);

      //--- Distancia mínima exigida por el bróker, medida contra el precio de CIERRE de la
      //--- posición (Bid en compra, Ask en venta), que es contra el que valida el servidor.
      //--- Si no se cumple, se omite la entrada en vez de ensanchar el SL: ampliarlo
      //--- aumentaría el riesgo por encima del configurado sin que el usuario lo pidiera.
      double stopRefPrice = GetStopReferencePrice(isBuy);
      if(hasSl && !IsStopDistanceValid(isBuy, true, stopRefPrice, sl))
        {
         if(m_cfg.verboseLog)
            Print(__FUNCTION__, ": SL a ", DoubleToString(MathAbs(stopRefPrice - sl), _Digits),
                  " no respeta la distancia mínima del bróker (",
                  DoubleToString(GetMinStopDistance(), _Digits), "); se omite la operación");
         return false;
        }
      if(hasTp && !IsStopDistanceValid(isBuy, false, stopRefPrice, tp))
        {
         if(m_cfg.verboseLog)
            Print(__FUNCTION__, ": TP a ", DoubleToString(MathAbs(stopRefPrice - tp), _Digits),
                  " no respeta la distancia mínima del bróker (",
                  DoubleToString(GetMinStopDistance(), _Digits), "); se omite la operación");
         return false;
        }

      double lots;
      if(!m_sizer.GetLots(isBuy, price, hasSl ? sl : 0.0, lots))
         return false;

      if(!HasFreeMarginFor(isBuy, lots, price))
        {
         if(m_cfg.verboseLog)
            Print(__FUNCTION__, ": margen libre insuficiente para ", DoubleToString(lots, 2),
                  " lotes; se omite la operación");
         return false;
        }

      bool result = isBuy ? m_trade.Buy(lots, _Symbol, price, sl, tp)
                           : m_trade.Sell(lots, _Symbol, price, sl, tp);

      //--- OrderSend puede devolver true con un retcode que no es ejecución: solo DONE,
      //--- DONE_PARTIAL o PLACED significan que hay posición (y consumen el nivel).
      uint retcode = m_trade.ResultRetcode();
      result = result && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL
                          || retcode == TRADE_RETCODE_PLACED);

      if(!result)
        {
         Print(__FUNCTION__, ": fallo al enviar orden, retcode=", m_trade.ResultRetcode(),
               " desc=", m_trade.ResultRetcodeDescription());
         return false;
        }

      m_cooldown.Register(triggeredLevel);
      return true;
     }

public:
   bool              Init(const SExpertConfig &cfg)
     {
      m_cfg = cfg;
      m_levelsReady = false;

      //--- Validaciones de configuración inválida (regla 6 del estándar y §5.2 del plan):
      //--- fallar explícito en OnInit, nunca asumir un valor por defecto silencioso.
      if(m_cfg.lotMode == LOT_MODE_RISK_PERCENT && !m_cfg.useSl && !m_cfg.useStructuralSl)
        {
         Print(__FUNCTION__, ": InpLotMode = LOT_MODE_RISK_PERCENT requiere InpUseStopLoss "
               "o InpUseStructuralSL activos (se necesita una distancia de SL para dimensionar el riesgo)");
         return false;
        }

      if(m_cfg.useStructuralSl && m_cfg.direction != DIR_BUY_ONLY)
        {
         Print(__FUNCTION__, ": InpUseStructuralSL = true requiere InpTradeDirection = DIR_BUY_ONLY "
               "(el SL estructural solo está definido para operativa de compra)");
         return false;
        }

      if(m_cfg.useStructuralSl
         && !m_structuralStop.Init(m_cfg.structuralSlMode, m_cfg.structuralSlPrice, m_cfg.structuralSlTimeframe,
                                   m_cfg.structuralSlLookbackBars, m_cfg.structuralSlHorizonBars,
                                   m_cfg.structuralSlRecentVolBars, m_cfg.structuralSlMaxTouchProbPct,
                                   m_cfg.structuralSlDriftWeight, m_cfg.verboseLog))
         return false;

      //--- El TP estructural necesita que el lado opuesto de la operativa tenga líneas
      //--- para elegir: InpMaxLinesAbove=0 deja sin resistencia posible para una compra,
      //--- InpMaxLinesBelow=0 deja sin soporte posible para una venta. Si la dirección
      //--- configurada puede producir ese lado, es una configuración inválida: toda
      //--- entrada de ese lado se omitiría para siempre (ver GetOppositeLevelPrice).
      if(m_cfg.useStructuralTp)
        {
         bool canBuy  = (m_cfg.direction == DIR_BUY_ONLY || m_cfg.direction == DIR_BOTH || m_cfg.direction == DIR_TREND_FOLLOW);
         bool canSell = (m_cfg.direction == DIR_SELL_ONLY || m_cfg.direction == DIR_BOTH || m_cfg.direction == DIR_TREND_FOLLOW);

         if(canBuy && m_cfg.maxLinesAbove <= 0)
           {
            Print(__FUNCTION__, ": InpUseStructuralTP = true con InpTradeDirection que permite compras "
                  "requiere InpMaxLinesAbove > 0 (se necesita una resistencia seleccionable para el TP)");
            return false;
           }
         if(canSell && m_cfg.maxLinesBelow <= 0)
           {
            Print(__FUNCTION__, ": InpUseStructuralTP = true con InpTradeDirection que permite ventas "
                  "requiere InpMaxLinesBelow > 0 (se necesita un soporte seleccionable para el TP)");
            return false;
           }
        }

      if(m_cfg.maxOpenPositions < 1)
        {
         Print(__FUNCTION__, ": InpMaxOpenPositions debe ser mayor o igual a 1");
         return false;
        }

      if(m_cfg.minEntryDistanceAtrMul < 0.0 || m_cfg.maxSpreadAtrMul < 0.0 || m_cfg.levelCooldownBars < 0
         || m_cfg.trailingStepAtrMul < 0.0 || m_cfg.timeDecayHalfLife < 0.0 || m_cfg.minSeparationAtrMul < 0.0)
        {
         Print(__FUNCTION__, ": InpMinEntryDistanceAtr, InpMaxSpreadAtr, InpLevelCooldownBars, "
               "InpTrailingStepAtrMultiplier, InpTimeDecayHalfLife e InpMinSeparationAtr no pueden ser negativos");
         return false;
        }

      if(m_cfg.maxTotalRiskPercent < 0.0)
        {
         Print(__FUNCTION__, ": InpMaxTotalRiskPercent no puede ser negativo");
         return false;
        }

      //--- El tope de riesgo total necesita medir la pérdida hasta el SL de cada
      //--- operación; sin SL la pérdida conjunta no es acotable.
      if(m_cfg.maxTotalRiskPercent > 0.0 && !m_cfg.useSl && !m_cfg.useStructuralSl)
        {
         Print(__FUNCTION__, ": InpMaxTotalRiskPercent > 0 requiere InpUseStopLoss o InpUseStructuralSL activos "
               "(sin SL el riesgo de la cartera no puede acotarse); usa 0 para desactivar el tope");
         return false;
        }

      if(m_cfg.maxTotalRiskPercent > 0.0 && m_cfg.lotMode == LOT_MODE_RISK_PERCENT
         && m_cfg.maxTotalRiskPercent < m_cfg.riskPercent)
        {
         Print(__FUNCTION__, ": InpMaxTotalRiskPercent (", DoubleToString(m_cfg.maxTotalRiskPercent, 2),
               ") es menor que InpRiskPercent (", DoubleToString(m_cfg.riskPercent, 2),
               "): ninguna operación usaría el riesgo configurado");
         return false;
        }

      //--- En cuenta de netting (la mayoría de los brókeres retail) el servidor solo
      //--- mantiene UNA posición neta por símbolo: un segundo Buy/Sell del mismo lado no
      //--- abre una posición nueva, agranda la existente (y del lado contrario la reduce
      //--- o la invierte). Con InpMaxOpenPositions > 1 el EA seguiría enviando órdenes
      //--- pensando que abrió varias posiciones distintas cuando en realidad no lo hizo;
      //--- se falla explícito en vez de operar sobre una premisa falsa.
      if(m_cfg.maxOpenPositions > 1 &&
         (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        {
         Print(__FUNCTION__, ": InpMaxOpenPositions > 1 requiere una cuenta de cobertura (hedging); "
               "esta cuenta es de netting y solo puede mantener una posición neta por símbolo");
         return false;
        }

      //--- Un offset de break even mayor o igual que su trigger deja el SL por delante
      //--- del precio actual: PositionModify fallaría en cada tick durante toda la vida
      //--- de la posición.
      if(m_cfg.useBreakEven && m_cfg.beOffsetAtrMul >= m_cfg.beTriggerAtrMul)
        {
         Print(__FUNCTION__, ": el offset de break even (", DoubleToString(m_cfg.beOffsetAtrMul, 4),
               " x ATR) debe ser menor que su trigger (", DoubleToString(m_cfg.beTriggerAtrMul, 4),
               " x ATR); si no, el SL quedaría por delante del precio");
         return false;
        }

      m_trade.SetExpertMagicNumber(m_cfg.magicNumber);
      m_trade.SetDeviationInPoints(m_cfg.slippage);
      //--- Modo de llenado leído del símbolo. Fijar FOK a ciegas hace que todas las
      //--- órdenes se rechacen con retcode 10030 en instrumentos que solo admiten IOC
      //--- o Return (ejecución por bolsa): el EA correría sin abrir jamás una operación.
      m_trade.SetTypeFilling(SelectFillingMode());

      m_baseBarMonitor.Init(m_cfg.baseTimeframe);

      m_atr.SetPeriod(m_cfg.atrPeriod);
      if(!m_atr.Register(m_cfg.baseTimeframe))
         return false;
      if(!m_atr.Register(m_cfg.trendTimeframe))
         return false;

      if(!m_repo.Init(m_cfg.baseTimeframe,
                       m_cfg.barsToAnalyze, m_cfg.minTouches,
                       m_cfg.kdeBandwidthAtrMul, m_cfg.kdeGridNodes, m_cfg.minDensityRatio, m_cfg.zoneWidthAtrMul,
                       m_cfg.relevanceRangeAtrMul, m_cfg.minWeight, m_cfg.distPenaltyLambda,
                       m_cfg.touchExponent, m_cfg.minSigmaAtr, m_cfg.timeDecayHalfLife,
                       m_cfg.tfExponent, m_cfg.mergeToleranceAtrMul, m_cfg.confluenceBonus,
                       m_cfg.maxLinesAbove, m_cfg.maxLinesBelow, m_cfg.minSeparationAtrMul,
                       m_atr))
         return false;

      m_renderer.Init(m_cfg.drawLevels, m_cfg.colorSupport, m_cfg.colorResistance);

      m_volFilter.Init(m_cfg.baseTimeframe, m_cfg.volumePeriod, m_cfg.useRealVolumeIfAvailable);

      if(!m_rsiFilter.Init(m_cfg.baseTimeframe, m_cfg.rsiPeriod, m_cfg.rsiOverbought, m_cfg.rsiOversold))
         return false;

      if(!m_trendFilter.Init(m_cfg.trendTimeframe, m_cfg.trendEmaPeriod))
         return false;

      m_riskManager.Init(m_cfg.magicNumber, m_cfg.baseTimeframe,
                          m_cfg.useBreakEven, m_cfg.beTriggerAtrMul, m_cfg.beOffsetAtrMul,
                          m_cfg.useTrailing, m_cfg.trailingTriggerAtrMul, m_cfg.trailingAtrMul,
                          m_cfg.trailingStepAtrMul);

      m_sizer.Init(m_cfg.lotMode, m_cfg.fixedLots, m_cfg.riskPercent,
                   m_cfg.maxTotalRiskPercent, m_cfg.magicNumber, m_cfg.verboseLog);

      m_cooldown.Init(m_cfg.baseTimeframe, m_cfg.levelCooldownBars);

      return true;
     }

   void              Deinit(void)
     {
      m_atr.Deinit();
      m_rsiFilter.Deinit();
      m_trendFilter.Deinit();
      m_renderer.Deinit();
     }

   //--- Gestión de riesgo (cada tick) + motor de niveles (solo al cierre de vela de la
   //--- TF base — regla 3 del estándar y §4 del plan; el cálculo de zonas/niveles no
   //--- depende de InpRequireConfirmation, solo cambia en vela nueva) + señal, evaluada
   //--- al cierre de vela en modo confirmado o en cada tick en modo inmediato.
   void              OnTick(void)
     {
      m_riskManager.Manage(m_trade, m_atr);

      bool isNewBar = m_baseBarMonitor.IsNewBar();

      //--- Antes de cualquier return temprano: el SL estructural se recalcula en su propia
      //--- TF de análisis, independiente de que el motor de niveles esté listo.
      if(m_cfg.useStructuralSl)
         m_structuralStop.Update(isNewBar);

      if(isNewBar)
        {
         //--- Los niveles de la vela anterior dejan de ser válidos desde ya: si el
         //--- recálculo falla más abajo, el modo inmediato no debe seguir operando en cada
         //--- tick sobre la selección vieja. Solo un recálculo exitoso vuelve a habilitarlo.
         m_levelsReady = false;

         //--- Pasos 1-2: recalcula puntos+zonas de cada TF que tuvo vela nueva (caché por TF)
         m_repo.RefreshZones(m_atr);

         if(!m_repo.IsFullyReady())
            return; // historial insuficiente todavía en alguna TF activa; no se opera ni se dibuja

         double currentPrice = iClose(_Symbol, m_cfg.baseTimeframe, 1);
         if(currentPrice <= 0.0)
            return;

         //--- Pasos 3-6: ajuste WLS + puntaje + escala por TF + fusión + selección
         if(!m_repo.RecomputeLevels(currentPrice, m_atr))
            return;

         SLevel resistances[], supports[];
         m_repo.GetResistances(resistances);
         m_repo.GetSupports(supports);
         m_renderer.Redraw(resistances, supports);

         if(m_cfg.verboseLog)
            LogSelectedLevels();

         m_levelsReady = true;
        }

      if(!m_levelsReady)
         return;

      //--- Modo confirmado (InpRequireConfirmation = true): la señal solo se evalúa al
      //--- cierre de vela, igual que antes. Modo inmediato (false): se evalúa en cada
      //--- tick, para operar en el instante en que el precio toca la línea.
      if(m_cfg.requireConfirmation && !isNewBar)
         return;

      //--- Regla 4: como máximo InpMaxOpenPositions posiciones propias abiertas a la vez
      //--- (por defecto 1). Se filtra por símbolo + magic, igual que CRiskManager: si el
      //--- gate mirara cualquier posición del símbolo, una operación manual o de otro EA
      //--- bloquearía las entradas mientras que la gestión de riesgo seguiría atendiendo
      //--- solo a las propias — dos criterios distintos.
      if(CountOwnPositions(m_cfg.magicNumber) >= m_cfg.maxOpenPositions)
         return;

      if(!IsAutoTradingAllowed())
         return;

      double atrBase;
      if(!m_atr.GetValue(m_cfg.baseTimeframe, 1, atrBase) || atrBase <= 0.0)
         return;

      //--- Filtro de spread: en modo inmediato se entra en el instante del toque, y un
      //--- spread ensanchado (rollover, noticias) convierte ese toque en una entrada a
      //--- mal precio con el SL comprimido. Medido en ATR para ser portable entre símbolos.
      if(m_cfg.maxSpreadAtrMul > 0.0)
        {
         double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(spread > m_cfg.maxSpreadAtrMul * atrBase)
            return;
        }

      double atrTrend = 0.0;
      if(m_cfg.direction == DIR_TREND_FOLLOW)
        {
         if(!m_atr.GetValue(m_cfg.trendTimeframe, 1, atrTrend) || atrTrend <= 0.0)
            return;
        }

      //--- Paso 7: señal de toque (confirmado o inmediato, según configuración) + filtros
      int    direction;
      double triggeredLevel;
      if(!m_signalEngine.Evaluate(m_repo, m_cfg.baseTimeframe, m_cfg.direction,
                                   m_cfg.touchToleranceAtrMul, atrBase,
                                   m_cfg.requireConfirmation, m_volFilter,
                                   m_cfg.useRsiFilter, m_rsiFilter,
                                   m_trendFilter, m_cfg.trendSlopeBars, m_cfg.trendThresholdAtrMul, atrTrend,
                                   m_cooldown,
                                   direction, triggeredLevel))
         return;

      OpenPosition(direction, triggeredLevel);
     }
  };
//+------------------------------------------------------------------+

//==================================================================+
//| PUNTO DE ENTRADA - OnInit / OnDeinit / OnTick
//==================================================================+

CExpertAdvisor g_ea;

//+------------------------------------------------------------------+
//| Resuelve PERIOD_CURRENT al período real del gráfico               |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES ResolveTimeframe(ENUM_TIMEFRAMES tf)
  {
   return (tf == PERIOD_CURRENT) ? _Period : tf;
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   SExpertConfig cfg;

   cfg.magicNumber   = InpMagicNumber;
   cfg.slippage       = InpSlippage;
   cfg.baseTimeframe = ResolveTimeframe(InpBaseTimeframe);
   cfg.verboseLog     = InpVerboseLog;
   cfg.requireConfirmation = InpRequireConfirmation;
   cfg.maxOpenPositions    = InpMaxOpenPositions;
   cfg.minEntryDistanceAtrMul = InpMinEntryDistanceAtr;
   cfg.maxSpreadAtrMul        = InpMaxSpreadAtr;

   cfg.barsToAnalyze = InpBarsToAnalyze;
   cfg.minTouches     = InpMinTouches;

   cfg.kdeBandwidthAtrMul = InpKdeBandwidthAtr;
   cfg.kdeGridNodes        = InpKdeGridNodes;
   cfg.minDensityRatio     = InpMinDensityRatio;
   cfg.zoneWidthAtrMul     = InpZoneWidthAtr;

   cfg.relevanceRangeAtrMul = InpRelevanceRangeAtr;
   cfg.minWeight             = InpMinWeight;
   cfg.distPenaltyLambda     = InpDistPenaltyLambda;
   cfg.touchExponent         = InpTouchExponent;
   cfg.minSigmaAtr           = InpMinSigmaAtr;
   cfg.timeDecayHalfLife     = InpTimeDecayHalfLife;

   cfg.tfExponent            = InpTfExponent;
   cfg.mergeToleranceAtrMul  = InpMergeToleranceAtr;
   cfg.confluenceBonus       = InpConfluenceBonus;

   cfg.maxLinesAbove      = InpMaxLinesAbove;
   cfg.maxLinesBelow      = InpMaxLinesBelow;
   cfg.minSeparationAtrMul = InpMinSeparationAtr;

   cfg.direction            = InpTradeDirection;
   cfg.touchToleranceAtrMul = InpTouchToleranceAtr;
   cfg.levelCooldownBars    = InpLevelCooldownBars;

   //--- PERIOD_CURRENT en el filtro de tendencia significa "la temporalidad base" (no el
   //--- período del gráfico si InpBaseTimeframe fue fijado explícitamente a otra cosa).
   cfg.trendTimeframe = (InpTrendTimeframe == PERIOD_CURRENT) ? cfg.baseTimeframe : InpTrendTimeframe;
   cfg.trendEmaPeriod       = InpTrendEmaPeriod;
   cfg.trendSlopeBars       = InpTrendSlopeBars;
   cfg.trendThresholdAtrMul = InpTrendThresholdAtr;

   cfg.volumePeriod             = InpVolumePeriod;
   cfg.useRealVolumeIfAvailable = InpUseRealVolume;

   cfg.useRsiFilter = InpUseRsiFilter;
   cfg.rsiPeriod     = InpRsiPeriod;
   cfg.rsiOverbought = InpRsiOverbought;
   cfg.rsiOversold   = InpRsiOversold;

   cfg.atrPeriod = InpAtrPeriod;

   cfg.useSl    = InpUseStopLoss;
   cfg.slAtrMul = InpSlAtrMultiplier;
   cfg.useTp    = InpUseTakeProfit;
   cfg.tpAtrMul = InpTpAtrMultiplier;

   cfg.useStructuralSl   = InpUseStructuralSL;
   cfg.structuralSlMode            = InpStructuralSLMode;
   cfg.structuralSlPrice           = InpStructuralSLPrice;
   cfg.structuralSlTimeframe       = ResolveTimeframe(InpStructSlTimeframe);
   cfg.structuralSlLookbackBars    = InpStructSlLookbackBars;
   cfg.structuralSlHorizonBars     = InpStructSlHorizonBars;
   cfg.structuralSlMaxTouchProbPct = InpStructSlMaxTouchProb;
   cfg.structuralSlDriftWeight     = InpStructSlDriftWeight;
   cfg.structuralSlRecentVolBars   = InpStructSlRecentVolBars;

   cfg.useStructuralTp = InpUseStructuralTP;

   cfg.useBreakEven    = InpUseBreakEven;
   cfg.beTriggerAtrMul = InpBreakEvenTriggerAtrMul;
   cfg.beOffsetAtrMul   = InpBreakEvenOffsetAtrMul;

   cfg.useTrailing           = InpUseTrailingStop;
   cfg.trailingTriggerAtrMul = InpTrailingTriggerAtrMultiplier;
   cfg.trailingAtrMul        = InpTrailingAtrMultiplier;
   cfg.trailingStepAtrMul    = InpTrailingStepAtrMultiplier;

   cfg.lotMode             = InpLotMode;
   cfg.fixedLots           = InpFixedLots;
   cfg.riskPercent         = InpRiskPercent;
   cfg.maxTotalRiskPercent = InpMaxTotalRiskPercent;

   cfg.drawLevels      = InpDrawLevels;
   cfg.colorSupport    = InpColorSupport;
   cfg.colorResistance = InpColorResistance;

   if(!g_ea.Init(cfg))
     {
      Print("Error inicializando SR_MTF_EA");
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
//| Criterio personalizado de optimización ("Custom max" en el        |
//| Probador). Con ~50 parámetros, maximizar el beneficio neto elige  |
//| la pasada más sobreajustada; el factor de recuperación (beneficio |
//| / drawdown máximo de equity) premia la relación retorno/riesgo.   |
//| Pasadas con muy pocas operaciones no tienen significancia         |
//| estadística y se descartan con 0. Complementar con Forward        |
//| (walk-forward) en el Probador para validar fuera de muestra.      |
//+------------------------------------------------------------------+
double OnTester(void)
  {
   double trades   = TesterStatistics(STAT_TRADES);
   double profit   = TesterStatistics(STAT_PROFIT);
   double equityDd = TesterStatistics(STAT_EQUITY_DD);

   if(trades < InpTesterMinTrades || profit <= 0.0)
      return 0.0;

   //--- Piso del drawdown en 1% del depósito: evita dividir por cero y que una pasada
   //--- con drawdown casi nulo (pocas operaciones afortunadas) domine el ranking.
   double ddFloor = 0.01 * TesterStatistics(STAT_INITIAL_DEPOSIT);
   return profit / MathMax(equityDd, ddFloor);
  }
//+------------------------------------------------------------------+
