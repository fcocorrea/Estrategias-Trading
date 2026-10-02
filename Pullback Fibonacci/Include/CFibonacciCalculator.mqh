//+------------------------------------------------------------------+
//|                                       CFibonacciCalculator.mqh |
//|  Calcula niveles de retroceso y extensión de Fibonacci sobre un  |
//|  impulso dado, y evalúa zona de entrada / confluencia con S-R.   |
//+------------------------------------------------------------------+
#ifndef FIBEA_FIBONACCI_CALCULATOR_MQH
#define FIBEA_FIBONACCI_CALCULATOR_MQH

#include "CSwingDetector.mqh"

class CFibonacciCalculator
  {
private:
   double            m_startPrice; // origen del impulso (mínimo en alcista, máximo en bajista)
   double            m_endPrice;   // destino del impulso (máximo en alcista, mínimo en bajista)
   double            m_range;
   int               m_trend;

public:
                     CFibonacciCalculator(void) : m_startPrice(0.0), m_endPrice(0.0),
                                                   m_range(0.0), m_trend(0) {}

   void              SetImpulse(int trend, double startPrice, double endPrice)
     {
      m_trend      = trend;
      m_startPrice = startPrice;
      m_endPrice   = endPrice;
      m_range      = MathAbs(endPrice - startPrice);
     }

   bool              IsValid(void) const { return m_range > 0.0; }

   //--- Precio del nivel de retroceso 'pct' (0.382, 0.5, 0.618, 0.786, ...) medido desde el destino
   double            RetracementPrice(double pct) const
     {
      if(m_trend == 1)
         return m_endPrice - m_range * pct;
      return m_endPrice + m_range * pct; // trend == -1
     }

   //--- Precio del nivel de extensión 'pct' (1.272, 1.618, ...) medido desde el origen
   double            ExtensionPrice(double pct) const
     {
      if(m_trend == 1)
         return m_startPrice + m_range * pct;
      return m_startPrice - m_range * pct; // trend == -1
     }

   //--- % de retroceso que representa 'price' respecto del impulso
   double            RetracementPercentOf(double price) const
     {
      if(m_range <= 0.0)
         return 0.0;
      return MathAbs(m_endPrice - price) / m_range;
     }

   bool              IsInEntryZone(double price, double minPct, double maxPct) const
     {
      double pct = RetracementPercentOf(price);
      return(pct >= minPct && pct <= maxPct);
     }

   bool              ExceedsMaxRetracement(double price, double maxPct) const
     {
      return(RetracementPercentOf(price) > maxPct);
     }

   //--- Confluencia: algún pivote previo (soporte/resistencia) cae dentro de la zona
   //--- de entrada (+/- tolerancia), lo que aumenta la probabilidad de rebote.
   bool              HasSRConfluence(SFibSwingPoint &highs[], SFibSwingPoint &lows[],
                                      double minPct, double maxPct, double tolerancePoints) const
     {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double tol   = tolerancePoints * point;

      double boundA = RetracementPrice(minPct);
      double boundB = RetracementPrice(maxPct);
      double zoneLow  = MathMin(boundA, boundB) - tol;
      double zoneHigh = MathMax(boundA, boundB) + tol;

      for(int i = 0; i < ArraySize(highs); i++)
         if(highs[i].price >= zoneLow && highs[i].price <= zoneHigh)
            return true;
      for(int i = 0; i < ArraySize(lows); i++)
         if(lows[i].price >= zoneLow && lows[i].price <= zoneHigh)
            return true;

      return false;
     }

   double            StartPrice(void) const { return m_startPrice; }
   double            EndPrice(void)   const { return m_endPrice; }
  };

#endif // FIBEA_FIBONACCI_CALCULATOR_MQH
