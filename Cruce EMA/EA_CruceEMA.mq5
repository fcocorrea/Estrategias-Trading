//+------------------------------------------------------------------+
//|                                                  EA_CruceEMA.mq5 |
//|      Cruce EMA9/EMA21 con filtro de tendencia EMA50, filtro     |
//|      de volumen y RSI, operativa solo al cierre de vela.        |
//|                                                                    |
//| Nota: la descripción de estrategia menciona soporte/resistencia  |
//| (zonas de dominio comprador/vendedor, rupturas, intercambio de   |
//| roles) como principio cualitativo, pero no define un método      |
//| cuantificable para detectar esos niveles. No se implementa como  |
//| regla programática para no inventar parámetros no especificados; |
//| la señal operativa es exclusivamente el sistema de cruce de EMAs.|
//+------------------------------------------------------------------+
#property copyright "Cruce EMA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Enum de modo de lotaje (usado por el grupo "Lotaje")
enum ENUM_LOT_MODE
  {
   LOT_MODE_FIXED,          // Lotaje fijo
   LOT_MODE_RISK_PERCENT    // % de riesgo sobre el balance
  };

input group "General"
input int    InpMagicNumber      = 240901;  // Magic number
input int    InpSlippage         = 10;      // Slippage en puntos

input group "Lotaje"
input ENUM_LOT_MODE InpLotMode   = LOT_MODE_FIXED; // Modo de cálculo del lotaje
input double InpFixedLots        = 0.10;    // Lotaje fijo (usado si InpLotMode = LOT_MODE_FIXED)
input double InpRiskPercent      = 1.0;     // % de balance a arriesgar por operación (usado si InpLotMode = LOT_MODE_RISK_PERCENT)

input group "ATR"
input int    InpAtrPeriod          = 14;    // Período ATR

input group "Stop Loss / Take Profit"
input bool   InpUseStopLoss        = true;  // Activar stop loss
input double InpSlAtrMultiplier    = 2.0;   // Stop loss = ATR x este múltiplo
input bool   InpUseTakeProfit      = true;  // Activar take profit
input double InpTpAtrMultiplier    = 4.0;   // Take profit = ATR x este múltiplo

input group "Break Even"
input bool   InpUseBreakEven           = true;  // Activar break even
input double InpBreakEvenTriggerAtrMul = 1.5;   // ATR x múltiplo de ganancia para activar break even
input double InpBreakEvenOffsetAtrMul  = 0.2;   // ATR x múltiplo de ganancia asegurado en break even

input group "Trailing Stop"
input bool   InpUseTrailingStop        = true;  // Activar trailing stop
input double InpTrailingAtrMultiplier  = 2.0;   // Distancia del trailing stop = ATR x este múltiplo
input double InpTrailingStepAtrMul     = 0.3;   // Paso mínimo para mover el trailing = ATR x este múltiplo

input group "Cruce de Medias"
input int    InpEmaFastPeriod    = 9;       // Período EMA rápida
input int    InpEmaMidPeriod     = 21;      // Período EMA intermedia
input int    InpEmaSlowPeriod    = 50;      // Período EMA lenta (filtro de tendencia)

input group "Filtro de Volumen"
input int    InpVolumePeriod     = 20;      // Velas para el promedio de volumen

input group "Filtro RSI"
input int    InpRsiPeriod        = 14;      // Período del RSI
input double InpRsiOverbought    = 70.0;    // Nivel de sobrecompra
input double InpRsiOversold      = 30.0;    // Nivel de sobreventa

//+------------------------------------------------------------------+
//| CBarMonitor: detecta el cierre de una vela nueva                |
//+------------------------------------------------------------------+
class CBarMonitor
  {
private:
   datetime m_lastBarTime;

public:
                     CBarMonitor(void) : m_lastBarTime(0) {}

   //--- true una única vez por vela nueva cerrada
   bool              IsNewBar(void)
     {
      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(currentBarTime == m_lastBarTime)
         return false;

      m_lastBarTime = currentBarTime;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| CEmaCrossSignal: sistema de cruce EMA9/EMA21 + filtro EMA50     |
//+------------------------------------------------------------------+
class CEmaCrossSignal
  {
private:
   int               m_fastHandle;
   int               m_midHandle;
   int               m_slowHandle;

   bool              CopyValue(int handle, int shift, double &out)
     {
      double buffer[];
      ArraySetAsSeries(buffer, true);

      if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando buffer, code=", GetLastError());
         return false;
        }

      out = buffer[0];
      return true;
     }

public:
                     CEmaCrossSignal(void) : m_fastHandle(INVALID_HANDLE),
                                              m_midHandle(INVALID_HANDLE),
                                              m_slowHandle(INVALID_HANDLE) {}

   bool              Init(int fastPeriod, int midPeriod, int slowPeriod)
     {
      m_fastHandle = iMA(_Symbol, _Period, fastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_midHandle  = iMA(_Symbol, _Period, midPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_slowHandle = iMA(_Symbol, _Period, slowPeriod, 0, MODE_EMA, PRICE_CLOSE);

      if(m_fastHandle == INVALID_HANDLE || m_midHandle == INVALID_HANDLE || m_slowHandle == INVALID_HANDLE)
        {
         Print(__FUNCTION__, ": no se pudo crear alguno de los handles de EMA, code=", GetLastError());
         return false;
        }

      return true;
     }

   void              Deinit(void)
     {
      if(m_fastHandle != INVALID_HANDLE)
         IndicatorRelease(m_fastHandle);
      if(m_midHandle != INVALID_HANDLE)
         IndicatorRelease(m_midHandle);
      if(m_slowHandle != INVALID_HANDLE)
         IndicatorRelease(m_slowHandle);
     }

   //--- Cruce evaluado entre la vela cerrada anterior (shift 2) y la última cerrada (shift 1).
   //--- Devuelve 1 (EMA9 cruzó por encima de EMA21), -1 (cruzó por debajo), 0 (sin cruce).
   bool              GetCross(int &crossOut)
     {
      double fastPrev, fastLast, midPrev, midLast;

      if(!CopyValue(m_fastHandle, 2, fastPrev) || !CopyValue(m_fastHandle, 1, fastLast))
         return false;
      if(!CopyValue(m_midHandle, 2, midPrev) || !CopyValue(m_midHandle, 1, midLast))
         return false;

      if(fastPrev <= midPrev && fastLast > midLast)
         crossOut = 1;
      else if(fastPrev >= midPrev && fastLast < midLast)
         crossOut = -1;
      else
         crossOut = 0;

      return true;
     }

   //--- Filtro de tendencia: precio de cierre de la última vela cerrada vs EMA50
   bool              GetTrend(int &trendOut)
     {
      double emaSlow;
      if(!CopyValue(m_slowHandle, 1, emaSlow))
         return false;

      double closePrice = iClose(_Symbol, _Period, 1);

      if(closePrice > emaSlow)
         trendOut = 1;
      else if(closePrice < emaSlow)
         trendOut = -1;
      else
         trendOut = 0;

      return true;
     }

   //--- Dirección de entrada: cruce + tendencia de fondo alineados.
   //--- 1 = entrada larga, -1 = entrada corta, 0 = sin señal.
   int               GetEntryDirection(void)
     {
      int cross, trend;
      if(!GetCross(cross) || !GetTrend(trend))
         return 0;

      if(cross == 1 && trend == 1)
         return 1;
      if(cross == -1 && trend == -1)
         return -1;

      return 0;
     }

   //--- Señal de salida para una posición abierta en 'positionDirection' (1 compra, -1 venta):
   //--- se revierte cuando el cruce y la tendencia se invierten simultáneamente.
   bool              IsExitSignal(int positionDirection)
     {
      int cross, trend;
      if(!GetCross(cross) || !GetTrend(trend))
         return false;

      if(positionDirection == 1)
         return (cross == -1 && trend == -1);
      if(positionDirection == -1)
         return (cross == 1 && trend == 1);

      return false;
     }
  };

//+------------------------------------------------------------------+
//| CSignalFilter: filtro obligatorio de volumen + RSI               |
//+------------------------------------------------------------------+
class CSignalFilter
  {
private:
   int               m_rsiHandle;
   int               m_volumePeriod;
   double            m_rsiOverbought;
   double            m_rsiOversold;

   //--- Volumen de la vela shift (1 = última vela cerrada)
   bool              GetVolume(int shift, long &volumeOut)
     {
      long volumeBuffer[];
      ArraySetAsSeries(volumeBuffer, true);

      if(CopyTickVolume(_Symbol, _Period, shift, 1, volumeBuffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando volumen, code=", GetLastError());
         return false;
        }

      volumeOut = volumeBuffer[0];
      return true;
     }

   //--- Promedio de volumen de las N velas previas a 'shift' (excluye 'shift')
   bool              GetAverageVolume(int shift, int period, double &avgOut)
     {
      long volumeBuffer[];
      ArraySetAsSeries(volumeBuffer, true);

      if(CopyTickVolume(_Symbol, _Period, shift + 1, period, volumeBuffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando volumen promedio, code=", GetLastError());
         return false;
        }

      long sum = 0;
      int  count = ArraySize(volumeBuffer);
      for(int i = 0; i < count; i++)
         sum += volumeBuffer[i];

      if(count == 0)
         return false;

      avgOut = (double)sum / (double)count;
      return true;
     }

   //--- RSI de la vela shift
   bool              GetRsi(int shift, double &rsiOut)
     {
      double rsiBuffer[];
      ArraySetAsSeries(rsiBuffer, true);

      if(CopyBuffer(m_rsiHandle, 0, shift, 1, rsiBuffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando RSI, code=", GetLastError());
         return false;
        }

      rsiOut = rsiBuffer[0];
      return true;
     }

public:
                     CSignalFilter(void) : m_rsiHandle(INVALID_HANDLE),
                                            m_volumePeriod(20),
                                            m_rsiOverbought(70.0),
                                            m_rsiOversold(30.0) {}

   bool              Init(int rsiPeriod, double rsiOverbought, double rsiOversold, int volumePeriod)
     {
      m_volumePeriod  = volumePeriod;
      m_rsiOverbought = rsiOverbought;
      m_rsiOversold   = rsiOversold;

      m_rsiHandle = iRSI(_Symbol, _Period, rsiPeriod, PRICE_CLOSE);
      if(m_rsiHandle == INVALID_HANDLE)
        {
         Print(__FUNCTION__, ": no se pudo crear el handle de RSI, code=", GetLastError());
         return false;
        }

      return true;
     }

   void              Deinit(void)
     {
      if(m_rsiHandle != INVALID_HANDLE)
         IndicatorRelease(m_rsiHandle);
     }

   //--- Regla 1: volumen de la última vela cerrada > promedio de las N previas.
   //--- Reduce señales falsas del cruce en mercados laterales o sin tendencia clara.
   bool              IsVolumeConfirmed(void)
     {
      long   lastVolume  = 0;
      double avgVolume   = 0.0;

      if(!GetVolume(1, lastVolume))
         return false;
      if(!GetAverageVolume(1, m_volumePeriod, avgVolume))
         return false;

      return (double)lastVolume > avgVolume;
     }

   //--- Regla 2: filtro RSI direccional.
   //--- Nunca comprar en sobrecompra, nunca vender en sobreventa.
   bool              IsRsiAllowed(int direction)
     {
      double rsi = 0.0;
      if(!GetRsi(1, rsi))
         return false;

      if(direction == 1 && rsi >= m_rsiOverbought)   // compra bloqueada en sobrecompra
         return false;
      if(direction == -1 && rsi <= m_rsiOversold)    // venta bloqueada en sobreventa
         return false;

      return true;
     }

   //--- Filtro combinado obligatorio: se aplica solo a la entrada, no a la salida,
   //--- ya que la salida es la reversión del propio sistema de cruce/tendencia.
   bool              IsAllowedToTrade(int direction)
     {
      return IsVolumeConfirmed() && IsRsiAllowed(direction);
     }
  };

//+------------------------------------------------------------------+
//| CAtrProvider: handle único de ATR, fuente de todas las           |
//| distancias de gestión de riesgo (SL, TP, break even, trailing). |
//+------------------------------------------------------------------+
class CAtrProvider
  {
private:
   int               m_handle;

public:
                     CAtrProvider(void) : m_handle(INVALID_HANDLE) {}

   bool              Init(int period)
     {
      m_handle = iATR(_Symbol, _Period, period);
      if(m_handle == INVALID_HANDLE)
        {
         Print(__FUNCTION__, ": no se pudo crear el handle de ATR, code=", GetLastError());
         return false;
        }
      return true;
     }

   void              Deinit(void)
     {
      if(m_handle != INVALID_HANDLE)
         IndicatorRelease(m_handle);
     }

   //--- Valor de ATR en la vela shift (0 = vela en formación, 1 = última vela cerrada)
   bool              GetValue(int shift, double &out)
     {
      double buffer[];
      ArraySetAsSeries(buffer, true);

      if(CopyBuffer(m_handle, 0, shift, 1, buffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando ATR, code=", GetLastError());
         return false;
        }

      out = buffer[0];
      return true;
     }
  };

//+------------------------------------------------------------------+
//| CRiskManager: break even + trailing stop sobre la posición       |
//| abierta, en múltiplos de ATR. Corre en cada tick (no solo al     |
//| cierre de vela): es gestión de riesgo, no señal de entrada/salida.|
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   long              m_magicNumber;
   bool              m_useBreakEven;
   double            m_beTriggerAtrMul;
   double            m_beOffsetAtrMul;
   bool              m_useTrailing;
   double            m_trailingAtrMul;
   double            m_trailingStepAtrMul;

   //--- true si 'candidate' protege más que 'current' (0 = sin SL, cualquier candidate es mejor)
   bool              IsBetterSL(bool isBuy, double candidate, double current)
     {
      if(current == 0.0)
         return true;
      return isBuy ? (candidate > current) : (candidate < current);
     }

public:
                     CRiskManager(void) : m_magicNumber(0),
                                           m_useBreakEven(true),
                                           m_beTriggerAtrMul(0),
                                           m_beOffsetAtrMul(0),
                                           m_useTrailing(true),
                                           m_trailingAtrMul(0),
                                           m_trailingStepAtrMul(0) {}

   void              Init(long magicNumber,
                           bool useBreakEven, double beTriggerAtrMul, double beOffsetAtrMul,
                           bool useTrailing, double trailingAtrMul, double trailingStepAtrMul)
     {
      m_magicNumber        = magicNumber;
      m_useBreakEven        = useBreakEven;
      m_beTriggerAtrMul     = beTriggerAtrMul;
      m_beOffsetAtrMul      = beOffsetAtrMul;
      m_useTrailing         = useTrailing;
      m_trailingAtrMul      = trailingAtrMul;
      m_trailingStepAtrMul  = trailingStepAtrMul;
     }

   void              Manage(CTrade &trade, CAtrProvider &atr)
     {
      if(!m_useBreakEven && !m_useTrailing)
         return;

      if(!PositionSelect(_Symbol))
         return;
      if(PositionGetInteger(POSITION_MAGIC) != m_magicNumber)
         return;

      double atrValue;
      if(!atr.GetValue(0, atrValue) || atrValue <= 0.0)
         return;

      bool   isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      double refPrice   = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                 : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitDistance = isBuy ? (refPrice - openPrice) : (openPrice - refPrice);

      double newSL = currentSL;

      //--- Break even: asegura 'offset' x ATR de ganancia una vez alcanzado el trigger
      if(m_useBreakEven && profitDistance >= m_beTriggerAtrMul * atrValue)
        {
         double candidate = isBuy ? openPrice + m_beOffsetAtrMul * atrValue
                                   : openPrice - m_beOffsetAtrMul * atrValue;
         if(IsBetterSL(isBuy, candidate, newSL))
            newSL = candidate;
        }

      //--- Trailing stop: sigue el precio a 'trailingAtrMul' x ATR, respetando el paso mínimo
      if(m_useTrailing && profitDistance >= m_trailingAtrMul * atrValue)
        {
         double candidate = isBuy ? refPrice - m_trailingAtrMul * atrValue
                                   : refPrice + m_trailingAtrMul * atrValue;
         double stepThreshold = isBuy ? currentSL + m_trailingStepAtrMul * atrValue
                                       : currentSL - m_trailingStepAtrMul * atrValue;

         bool passesStep = (currentSL == 0.0) || IsBetterSL(isBuy, candidate, stepThreshold);

         if(passesStep && IsBetterSL(isBuy, candidate, newSL))
            newSL = candidate;
        }

      if(newSL != currentSL)
        {
         if(!trade.PositionModify(_Symbol, newSL, currentTP))
           {
            Print(__FUNCTION__, ": fallo al modificar SL, retcode=", trade.ResultRetcode(),
                  " desc=", trade.ResultRetcodeDescription());
           }
        }
     }
  };

//+------------------------------------------------------------------+
//| CPositionSizer: lotaje fijo o calculado a partir de un % de      |
//| riesgo sobre el balance y la distancia de SL (en precio).        |
//+------------------------------------------------------------------+
class CPositionSizer
  {
private:
   ENUM_LOT_MODE     m_mode;
   double            m_fixedLots;
   double            m_riskPercent;

   double            NormalizeLots(double lots)
     {
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      double normalized = MathFloor(lots / lotStep) * lotStep;
      return MathMax(minLot, MathMin(maxLot, normalized));
     }

public:
                     CPositionSizer(void) : m_mode(LOT_MODE_FIXED),
                                             m_fixedLots(0.10),
                                             m_riskPercent(1.0) {}

   void              Init(ENUM_LOT_MODE mode, double fixedLots, double riskPercent)
     {
      m_mode        = mode;
      m_fixedLots   = fixedLots;
      m_riskPercent = riskPercent;
     }

   //--- 'slDistance' es la distancia de SL en precio (> 0), obligatoria en modo % de riesgo
   bool              GetLots(double slDistance, double &lotsOut)
     {
      if(m_mode == LOT_MODE_FIXED)
        {
         lotsOut = NormalizeLots(m_fixedLots);
         return true;
        }

      if(slDistance <= 0.0)
        {
         Print(__FUNCTION__, ": distancia de SL inválida para calcular lotaje por % de riesgo");
         return false;
        }

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0.0 || tickValue <= 0.0)
        {
         Print(__FUNCTION__, ": tick value/size inválido para el símbolo");
         return false;
        }

      double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * (m_riskPercent / 100.0);
      double lossPerLot = (slDistance / tickSize) * tickValue;
      if(lossPerLot <= 0.0)
        {
         Print(__FUNCTION__, ": no se pudo calcular la pérdida por lote");
         return false;
        }

      lotsOut = NormalizeLots(riskMoney / lossPerLot);
      return true;
     }
  };

//+------------------------------------------------------------------+
//| CExpertAdvisor: orquesta señal de cruce + filtros + CTrade       |
//+------------------------------------------------------------------+
class CExpertAdvisor
  {
private:
   CTrade            m_trade;
   CBarMonitor       m_barMonitor;
   CEmaCrossSignal   m_emaSignal;
   CSignalFilter     m_filter;
   CRiskManager      m_riskManager;
   CAtrProvider      m_atr;
   CPositionSizer    m_sizer;

   bool              m_useSl;
   double            m_slAtrMul;
   bool              m_useTp;
   double            m_tpAtrMul;

   //--- Dirección de la posición abierta actual en este símbolo/magic (1, -1, 0 = sin posición)
   int               GetOpenPositionDirection(void)
     {
      if(!PositionSelect(_Symbol))
         return 0;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         return 0;

      return (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
     }

   bool              ClosePosition(void)
     {
      bool result = m_trade.PositionClose(_Symbol);
      if(!result)
        {
         Print(__FUNCTION__, ": fallo al cerrar posición, retcode=", m_trade.ResultRetcode(),
               " desc=", m_trade.ResultRetcodeDescription());
        }
      return result;
     }

   bool              OpenPosition(ENUM_ORDER_TYPE orderType)
     {
      double price = (orderType == ORDER_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                     : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      //--- ATR de la última vela cerrada, consistente con la señal evaluada solo al cierre de vela
      double atrValue;
      if(!m_atr.GetValue(1, atrValue) || atrValue <= 0.0)
         return false;

      double slDistance = m_useSl ? m_slAtrMul * atrValue : 0.0;

      double lots;
      if(!m_sizer.GetLots(slDistance, lots))
         return false;

      double sl = 0.0, tp = 0.0;

      if(m_useSl)
         sl = (orderType == ORDER_TYPE_BUY) ? price - slDistance
                                             : price + slDistance;
      if(m_useTp)
         tp = (orderType == ORDER_TYPE_BUY) ? price + m_tpAtrMul * atrValue
                                             : price - m_tpAtrMul * atrValue;

      bool result = (orderType == ORDER_TYPE_BUY)
                    ? m_trade.Buy(lots, _Symbol, price, sl, tp)
                    : m_trade.Sell(lots, _Symbol, price, sl, tp);

      if(!result)
        {
         Print(__FUNCTION__, ": fallo al enviar orden, retcode=", m_trade.ResultRetcode(),
               " desc=", m_trade.ResultRetcodeDescription());
        }

      return result;
     }

public:
   bool              Init(int magicNumber, int slippage,
                           ENUM_LOT_MODE lotMode, double fixedLots, double riskPercent,
                           int atrPeriod,
                           bool useSl, double slAtrMul, bool useTp, double tpAtrMul,
                           bool useBreakEven, double beTriggerAtrMul, double beOffsetAtrMul,
                           bool useTrailing, double trailingAtrMul, double trailingStepAtrMul,
                           int emaFastPeriod, int emaMidPeriod, int emaSlowPeriod,
                           int rsiPeriod, double rsiOverbought, double rsiOversold,
                           int volumePeriod)
     {
      //--- El modo % de riesgo necesita una distancia de SL para dimensionar el lotaje
      if(lotMode == LOT_MODE_RISK_PERCENT && !useSl)
        {
         Print(__FUNCTION__, ": InpLotMode = LOT_MODE_RISK_PERCENT requiere InpUseStopLoss = true");
         return false;
        }

      m_useSl    = useSl;
      m_slAtrMul = slAtrMul;
      m_useTp    = useTp;
      m_tpAtrMul = tpAtrMul;

      m_trade.SetExpertMagicNumber(magicNumber);
      m_trade.SetDeviationInPoints(slippage);
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);

      m_sizer.Init(lotMode, fixedLots, riskPercent);

      if(!m_atr.Init(atrPeriod))
         return false;

      m_riskManager.Init(magicNumber, useBreakEven, beTriggerAtrMul, beOffsetAtrMul,
                          useTrailing, trailingAtrMul, trailingStepAtrMul);

      if(!m_emaSignal.Init(emaFastPeriod, emaMidPeriod, emaSlowPeriod))
         return false;

      return m_filter.Init(rsiPeriod, rsiOverbought, rsiOversold, volumePeriod);
     }

   void              Deinit(void)
     {
      m_atr.Deinit();
      m_emaSignal.Deinit();
      m_filter.Deinit();
     }

   //--- Regla 3: toda la lógica de señal se evalúa una sola vez por vela nueva.
   //--- La gestión de riesgo (break even/trailing) corre cada tick, fuera de esa regla.
   void              OnTick(void)
     {
      m_riskManager.Manage(m_trade, m_atr);

      if(!m_barMonitor.IsNewBar())
         return;

      int openDirection = GetOpenPositionDirection();

      //--- Regla 4: si ya hay posición abierta, solo se evalúa su salida (reversión del cruce/tendencia)
      if(openDirection != 0)
        {
         if(m_emaSignal.IsExitSignal(openDirection))
            ClosePosition();
         return;
        }

      int direction = m_emaSignal.GetEntryDirection();
      if(direction == 0)
         return;

      if(!m_filter.IsAllowedToTrade(direction))
         return;

      if(direction == 1)
         OpenPosition(ORDER_TYPE_BUY);
      else if(direction == -1)
         OpenPosition(ORDER_TYPE_SELL);
     }
  };

CExpertAdvisor g_ea;

//+------------------------------------------------------------------+
int OnInit(void)
  {
   if(!g_ea.Init(InpMagicNumber, InpSlippage,
                  InpLotMode, InpFixedLots, InpRiskPercent,
                  InpAtrPeriod,
                  InpUseStopLoss, InpSlAtrMultiplier, InpUseTakeProfit, InpTpAtrMultiplier,
                  InpUseBreakEven, InpBreakEvenTriggerAtrMul, InpBreakEvenOffsetAtrMul,
                  InpUseTrailingStop, InpTrailingAtrMultiplier, InpTrailingStepAtrMul,
                  InpEmaFastPeriod, InpEmaMidPeriod, InpEmaSlowPeriod,
                  InpRsiPeriod, InpRsiOverbought, InpRsiOversold,
                  InpVolumePeriod))
     {
      Print("Error inicializando el EA");
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
