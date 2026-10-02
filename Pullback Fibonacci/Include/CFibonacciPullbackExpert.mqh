//+------------------------------------------------------------------+
//|                                  CFibonacciPullbackExpert.mqh |
//|  Orquesta: filtro de tendencia -> impulso/Fibonacci -> zona de   |
//|  entrada -> confirmación -> filtro obligatorio volumen/RSI ->    |
//|  ejecución (CTradeManager) -> gestión de la posición abierta.    |
//+------------------------------------------------------------------+
#ifndef FIBEA_EXPERT_MQH
#define FIBEA_EXPERT_MQH

#include "CBarMonitor.mqh"
#include "CSwingDetector.mqh"
#include "CTrendFilter.mqh"
#include "CFibonacciCalculator.mqh"
#include "CConfirmationSignal.mqh"
#include "CSignalFilter.mqh"
#include "CVolumeTrendFilter.mqh"
#include "CRiskManager.mqh"
#include "CTradeManager.mqh"

enum ENUM_ENTRY_MODE
  {
   ENTRY_AT_CLOSE    = 0,   // entra a mercado al cierre de la vela de confirmación
   ENTRY_ON_BREAKOUT = 1    // orden pendiente al quiebre del máximo/mínimo de esa vela
  };

//--- Agrupa todos los inputs del EA para pasarlos de una vez a la clase orquestadora
struct SFibExpertParams
  {
   int             magic;
   int             slippage;

   double          riskPercent;
   double          fixedLots;

   int             trendEmaPeriod;
   bool            requireSwingStructure;

   int             swingLookbackBars;
   double          fibMinRetracement;
   double          fibMaxRetracement;
   double          fibExtremeRetracement;
   bool            requireSrConfluence;
   double          srConfluenceTolerancePoints;

   bool            useCandlePattern;
   bool            useEmaCross;
   int             fastEmaPeriod;
   int             slowEmaPeriod;
   bool            useRsiDivergence;

   int             volumePeriod;
   int             rsiPeriod;
   double          rsiOverbought;
   double          rsiOversold;

   bool            requireDecreasingPullbackVolume;
   int             pullbackVolumeLookback;

   ENUM_ENTRY_MODE entryMode;

   double          slBufferPoints;
   ENUM_TP1_METHOD tp1Method;
   double          fibExtension1;
   double          fibExtension2;
   double          partialClosePercent;
   bool            useTrailingAfterPartial;
   double          trailingPoints;
  };

class CFibonacciPullbackExpert
  {
private:
   SFibExpertParams     m_p;

   CBarMonitor          m_barMonitor;
   CSwingDetector       m_swingDetector;
   CTrendFilter         m_trendFilter;
   CSignalFilter        m_signalFilter;
   CConfirmationSignal  m_confirmation;
   CRiskManager         m_riskManager;
   CTradeManager        m_tradeManager;

   //--- Evalúa e intenta ejecutar la entrada para la tendencia dada, usando los
   //--- pivotes ya recolectados para esta vela.
   bool              TryEnter(int trend, SFibSwingPoint &highs[], SFibSwingPoint &lows[])
     {
      SFibSwingPoint startPoint, endPoint;
      if(!CSwingDetector::GetLastImpulse(trend, highs, lows, startPoint, endPoint))
         return false;

      CFibonacciCalculator fib;
      fib.SetImpulse(trend, startPoint.price, endPoint.price);
      if(!fib.IsValid())
         return false;

      double lastClose[];
      ArraySetAsSeries(lastClose, true);
      if(CopyClose(_Symbol, _Period, 1, 1, lastClose) <= 0)
         return false;
      double refPrice = lastClose[0];

      //--- Descarta si el retroceso ya superó el 78.6% (posible cambio de tendencia)
      if(fib.ExceedsMaxRetracement(refPrice, m_p.fibExtremeRetracement))
         return false;

      //--- Exige que el precio esté dentro de la zona de entrada (38.2%-61.8%)
      if(!fib.IsInEntryZone(refPrice, m_p.fibMinRetracement, m_p.fibMaxRetracement))
         return false;

      //--- Confluencia con soporte/resistencia previo dentro de la zona
      if(m_p.requireSrConfluence &&
         !fib.HasSRConfluence(highs, lows, m_p.fibMinRetracement, m_p.fibMaxRetracement,
                               m_p.srConfluenceTolerancePoints))
         return false;

      //--- El volumen debe disminuir durante el retroceso frente al del impulso
      if(m_p.requireDecreasingPullbackVolume &&
         !CVolumeTrendFilter::IsPullbackVolumeDecreasing(startPoint.shift, endPoint.shift,
                                                           m_p.pullbackVolumeLookback))
         return false;

      //--- Señal de confirmación: patrón de velas, cruce de EMAs o divergencia de RSI
      if(!m_confirmation.IsConfirmed(trend, highs, lows))
         return false;

      //--- Capa obligatoria del estándar: volumen > promedio 20 + RSI direccional
      if(!m_signalFilter.IsAllowedToTrade(trend))
         return false;

      double slPrice  = m_riskManager.ComputeStopLoss(trend, fib.RetracementPrice(m_p.fibMaxRetracement));
      double tp1Price = m_riskManager.ComputeTp1(trend, fib, endPoint.price);
      double tp2Price = m_riskManager.ComputeTp2(fib);

      double entryPrice = (trend == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lots = m_riskManager.CalculateLotSize(entryPrice, slPrice);
      if(lots <= 0.0)
         return false;

      if(m_p.entryMode == ENTRY_AT_CLOSE)
         return m_tradeManager.OpenMarketPosition(trend, lots, slPrice, tp1Price, tp2Price);

      //--- ENTRY_ON_BREAKOUT: quiebre del máximo/mínimo de la vela de confirmación (shift 1)
      double high1[], low1[];
      ArraySetAsSeries(high1, true);
      ArraySetAsSeries(low1, true);
      if(CopyHigh(_Symbol, _Period, 1, 1, high1) <= 0) return false;
      if(CopyLow(_Symbol, _Period, 1, 1, low1) <= 0)   return false;

      double triggerPrice = (trend == 1) ? high1[0] : low1[0];
      return m_tradeManager.OpenStopOrder(trend, lots, triggerPrice, slPrice, tp1Price, tp2Price);
     }

public:
   bool              Init(const SFibExpertParams &params)
     {
      m_p = params;

      m_swingDetector.Init(m_p.swingLookbackBars);

      if(!m_trendFilter.Init(m_p.trendEmaPeriod, m_p.requireSwingStructure))
         return false;

      if(!m_signalFilter.Init(m_p.rsiPeriod, m_p.rsiOverbought, m_p.rsiOversold, m_p.volumePeriod))
         return false;

      if(!m_confirmation.Init(m_p.useCandlePattern, m_p.useEmaCross, m_p.useRsiDivergence,
                               m_p.fastEmaPeriod, m_p.slowEmaPeriod, m_p.rsiPeriod))
         return false;

      m_riskManager.Init(m_p.riskPercent, m_p.fixedLots, m_p.slBufferPoints,
                          m_p.tp1Method, m_p.fibExtension1, m_p.fibExtension2);

      m_tradeManager.Init(m_p.magic, m_p.slippage, m_p.partialClosePercent,
                           m_p.useTrailingAfterPartial, m_p.trailingPoints);

      return true;
     }

   void              Deinit(void)
     {
      m_trendFilter.Deinit();
      m_confirmation.Deinit();
      m_signalFilter.Deinit();
     }

   void              OnTick(void)
     {
      //--- Gestión de la posición abierta (parcial + trailing): en cada tick, no es señal de entrada
      m_tradeManager.ManageOpenPosition();

      if(!m_barMonitor.IsNewBar())
         return;

      if(m_p.entryMode == ENTRY_ON_BREAKOUT)
         m_tradeManager.CancelPendingOrders(); // la pendiente de la vela anterior ya expiró

      if(PositionSelect(_Symbol))
         return; // regla obligatoria: una sola operación abierta a la vez

      if(m_p.entryMode == ENTRY_ON_BREAKOUT && m_tradeManager.HasPendingOrder())
         return;

      SFibSwingPoint highs[], lows[];
      if(!m_swingDetector.CollectPivots(highs, lows))
         return;

      int trend = m_trendFilter.GetTrend(highs, lows);
      if(trend == 0)
         return;

      TryEnter(trend, highs, lows);
     }
  };

#endif // FIBEA_EXPERT_MQH
