//+------------------------------------------------------------------+
//|                                                CRiskManager.mqh |
//|  Lotaje por riesgo %, stop loss bajo/sobre 61.8% y objetivos de   |
//|  toma de ganancias (extensión de Fibonacci o extremo previo).    |
//+------------------------------------------------------------------+
#ifndef FIBEA_RISK_MANAGER_MQH
#define FIBEA_RISK_MANAGER_MQH

#include "CFibonacciCalculator.mqh"

enum ENUM_TP1_METHOD
  {
   TP1_EXTENSION_1272 = 0,   // primer objetivo = extensión 127.2%
   TP1_PREVIOUS_SWING = 1    // primer objetivo = máximo/mínimo previo del impulso
  };

class CRiskManager
  {
private:
   double            m_riskPercent;
   double            m_fixedLots;
   double            m_slBufferPoints;
   ENUM_TP1_METHOD   m_tp1Method;
   double            m_ext1Pct;
   double            m_ext2Pct;

public:
                     CRiskManager(void) : m_riskPercent(0.0), m_fixedLots(0.10), m_slBufferPoints(30.0),
                                           m_tp1Method(TP1_EXTENSION_1272), m_ext1Pct(1.272), m_ext2Pct(1.618) {}

   void              Init(double riskPercent, double fixedLots, double slBufferPoints,
                           ENUM_TP1_METHOD tp1Method, double ext1Pct, double ext2Pct)
     {
      m_riskPercent    = riskPercent;
      m_fixedLots      = fixedLots;
      m_slBufferPoints = slBufferPoints;
      m_tp1Method      = tp1Method;
      m_ext1Pct        = ext1Pct;
      m_ext2Pct        = ext2Pct;
     }

   //--- SL justo por debajo (largo) o por encima (corto) del nivel 61.8%: punto de
   //--- invalidación de la hipótesis de pullback.
   double            ComputeStopLoss(int trend, double fib618Price) const
     {
      double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double buffer = m_slBufferPoints * point;
      return(trend == 1) ? (fib618Price - buffer) : (fib618Price + buffer);
     }

   double            ComputeTp1(int trend, const CFibonacciCalculator &fib, double previousSwingPrice) const
     {
      if(m_tp1Method == TP1_PREVIOUS_SWING && previousSwingPrice > 0.0)
         return previousSwingPrice;
      return fib.ExtensionPrice(m_ext1Pct);
     }

   double            ComputeTp2(const CFibonacciCalculator &fib) const
     {
      return fib.ExtensionPrice(m_ext2Pct);
     }

   //--- Lotaje por riesgo % del balance; si InpRiskPercent <= 0 usa lotaje fijo
   double            CalculateLotSize(double entryPrice, double slPrice) const
     {
      if(m_riskPercent <= 0.0)
         return m_fixedLots;

      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney = balance * m_riskPercent / 100.0;

      double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double slDistance = MathAbs(entryPrice - slPrice);
      if(tickSize <= 0.0 || slDistance <= 0.0)
         return m_fixedLots;

      double moneyPerLot = (slDistance / tickSize) * tickValue;
      if(moneyPerLot <= 0.0)
         return m_fixedLots;

      double lots = riskMoney / moneyPerLot;

      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

      lots = MathFloor(lots / lotStep) * lotStep;
      lots = MathMax(lotMin, MathMin(lotMax, lots));

      return lots;
     }
  };

#endif // FIBEA_RISK_MANAGER_MQH
