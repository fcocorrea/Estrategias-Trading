//+------------------------------------------------------------------+
//|                                               CTrendDetector.mqh |
//|  Determina la tendencia principal (alcista, bajista o lateral)   |
//|  a partir de la secuencia de picos y valles confirmados por un   |
//|  ZigZag basado en ATR, sobre velas cerradas de D1 o superior.    |
//|                                                                  |
//|   - Alcista: picos y valles sucesivamente más altos (HH + HL).   |
//|   - Bajista: picos y valles sucesivamente más bajos (LH + LL).   |
//|   - Lateral: picos/valles horizontales o estructura mixta.       |
//+------------------------------------------------------------------+
#ifndef TREND_DETECTOR_MQH
#define TREND_DETECTOR_MQH

#define TREND_DETECTOR_MIN_EXTRA_BARS 10

enum ENUM_MARKET_TREND
  {
   TREND_BEARISH  = -1, // Bajista
   TREND_SIDEWAYS = 0,  // Lateral
   TREND_BULLISH  = 1   // Alcista
  };

//--- Posición de un pivote respecto al pivote anterior del mismo tipo
enum ENUM_PIVOT_RELATION
  {
   PIVOT_FIRST,   // sin pivote previo con el que comparar
   PIVOT_HIGHER,
   PIVOT_LOWER,
   PIVOT_EQUAL    // diferencia dentro de la tolerancia de horizontalidad
  };

struct STrendPivot
  {
   datetime             time;
   double               price;
   bool                 isHigh;
   ENUM_PIVOT_RELATION  relation;
  };

class CTrendDetector
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_lookback;
   int               m_atrPeriod;
   double            m_atrMultiplier;
   double            m_equalTolerance;
   int               m_comparisons;

   STrendPivot       m_pivots[];   // ordenados del más antiguo al más reciente
   ENUM_MARKET_TREND m_trend;
   string            m_reason;
   double            m_lastClose;

   //--- ATR de Wilder; los valores previos a la primera media completa quedan en 0
   static void       ComputeAtr(const MqlRates &rates[], int period, double &atr[])
     {
      int size = ArraySize(rates);
      ArrayResize(atr, size);
      ArrayInitialize(atr, 0.0);

      double trSum = 0.0;
      for(int i = 0; i < size; i++)
        {
         double tr = rates[i].high - rates[i].low;
         if(i > 0)
            tr = MathMax(tr, MathMax(MathAbs(rates[i].high - rates[i - 1].close),
                                     MathAbs(rates[i].low - rates[i - 1].close)));

         if(i < period)
           {
            trSum += tr;
            if(i == period - 1)
               atr[i] = trSum / period;
            continue;
           }

         atr[i] = (atr[i - 1] * (period - 1) + tr) / period;
        }
     }

   void              AddPivot(datetime time, double price, bool isHigh, double tolerance)
     {
      int n = ArraySize(m_pivots);
      ArrayResize(m_pivots, n + 1, 64);
      m_pivots[n].time     = time;
      m_pivots[n].price    = price;
      m_pivots[n].isHigh   = isHigh;
      m_pivots[n].relation = PIVOT_FIRST;

      //--- El ZigZag alterna picos y valles: el anterior del mismo tipo está dos posiciones atrás
      if(n < 2 || m_pivots[n - 2].isHigh != isHigh)
         return;

      double diff = price - m_pivots[n - 2].price;
      if(diff > tolerance)
         m_pivots[n].relation = PIVOT_HIGHER;
      else
         if(diff < -tolerance)
            m_pivots[n].relation = PIVOT_LOWER;
         else
            m_pivots[n].relation = PIVOT_EQUAL;
     }

   //--- Un swing se confirma cuando el precio revierte atrMultiplier x ATR desde su extremo.
   //--- No se revierte en la misma vela que marca el extremo: el orden intrabarra es desconocido.
   void              BuildZigZag(const MqlRates &rates[], const double &atr[])
     {
      ArrayResize(m_pivots, 0);

      int    start       = m_atrPeriod - 1;
      int    direction   = 0;
      double candHigh    = rates[start].high;
      double candLow     = rates[start].low;
      int    candHighIdx = start;
      int    candLowIdx  = start;

      for(int i = start + 1; i < ArraySize(rates); i++)
        {
         double threshold = m_atrMultiplier * atr[i];

         if(direction == 0)
           {
            if(rates[i].high > candHigh)
              {
               candHigh    = rates[i].high;
               candHighIdx = i;
              }
            if(rates[i].low < candLow)
              {
               candLow    = rates[i].low;
               candLowIdx = i;
              }
            if(candHigh - candLow < threshold || candHighIdx == candLowIdx)
               continue;

            if(candHighIdx > candLowIdx)
              {
               AddPivot(rates[candLowIdx].time, candLow, false, m_equalTolerance * atr[candLowIdx]);
               direction = 1;
              }
            else
              {
               AddPivot(rates[candHighIdx].time, candHigh, true, m_equalTolerance * atr[candHighIdx]);
               direction = -1;
              }
            continue;
           }

         if(direction == 1)
           {
            if(rates[i].high > candHigh)
              {
               candHigh    = rates[i].high;
               candHighIdx = i;
               continue;
              }
            if(candHigh - rates[i].low >= threshold)
              {
               AddPivot(rates[candHighIdx].time, candHigh, true, m_equalTolerance * atr[candHighIdx]);
               direction  = -1;
               candLow    = rates[i].low;
               candLowIdx = i;
              }
            continue;
           }

         if(rates[i].low < candLow)
           {
            candLow    = rates[i].low;
            candLowIdx = i;
            continue;
           }
         if(rates[i].high - candLow >= threshold)
           {
            AddPivot(rates[candLowIdx].time, candLow, false, m_equalTolerance * atr[candLowIdx]);
            direction   = 1;
            candHigh    = rates[i].high;
            candHighIdx = i;
           }
        }
     }

   int               LastPivotIndex(bool isHigh) const
     {
      for(int i = ArraySize(m_pivots) - 1; i >= 0; i--)
         if(m_pivots[i].isHigh == isHigh)
            return i;
      return -1;
     }

   void              Classify(void)
     {
      int  highCount = 0, lowCount = 0;
      bool highsUp = true, highsDown = true, lowsUp = true, lowsDown = true;

      for(int i = ArraySize(m_pivots) - 1; i >= 0; i--)
        {
         if(highCount >= m_comparisons && lowCount >= m_comparisons)
            break;

         ENUM_PIVOT_RELATION relation = m_pivots[i].relation;
         if(relation == PIVOT_FIRST)
            break;

         if(m_pivots[i].isHigh)
           {
            if(highCount >= m_comparisons)
               continue;
            highCount++;
            if(relation != PIVOT_HIGHER)
               highsUp = false;
            if(relation != PIVOT_LOWER)
               highsDown = false;
           }
         else
           {
            if(lowCount >= m_comparisons)
               continue;
            lowCount++;
            if(relation != PIVOT_HIGHER)
               lowsUp = false;
            if(relation != PIVOT_LOWER)
               lowsDown = false;
           }
        }

      m_trend = TREND_SIDEWAYS;
      if(highCount < m_comparisons || lowCount < m_comparisons)
        {
         m_reason = "swings insuficientes";
         return;
        }

      const STrendPivot lastHigh = m_pivots[LastPivotIndex(true)];
      const STrendPivot lastLow  = m_pivots[LastPivotIndex(false)];
      m_reason = PivotLabel(lastHigh) + "+" + PivotLabel(lastLow);

      if(highsUp && lowsUp)
         m_trend = TREND_BULLISH;
      else
         if(highsDown && lowsDown)
            m_trend = TREND_BEARISH;

      //--- Teoría de Dow: la tendencia queda en duda al perforar el último swing que la sostiene
      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      if(m_trend == TREND_BULLISH && m_lastClose < lastLow.price)
        {
         m_trend  = TREND_SIDEWAYS;
         m_reason = "cierre bajo el último HL " + DoubleToString(lastLow.price, digits);
        }
      else
         if(m_trend == TREND_BEARISH && m_lastClose > lastHigh.price)
           {
            m_trend  = TREND_SIDEWAYS;
            m_reason = "cierre sobre el último LH " + DoubleToString(lastHigh.price, digits);
           }
     }

public:
                     CTrendDetector(void) : m_symbol(""), m_timeframe(PERIOD_D1), m_lookback(500),
                     m_atrPeriod(14), m_atrMultiplier(3.0), m_equalTolerance(0.5), m_comparisons(1),
                     m_trend(TREND_SIDEWAYS), m_reason(""), m_lastClose(0.0) {}

   bool              Init(const string symbol, ENUM_TIMEFRAMES timeframe, int lookbackBars,
                          int atrPeriod, double atrMultiplier, double equalTolerance, int comparisons)
     {
      if(timeframe == PERIOD_CURRENT)
         timeframe = _Period;

      if(PeriodSeconds(timeframe) < PeriodSeconds(PERIOD_D1))
        {
         Print(__FUNCTION__, ": el timeframe de análisis debe ser D1 o superior");
         return false;
        }
      if(atrPeriod < 1 || atrMultiplier <= 0.0 || equalTolerance < 0.0 || comparisons < 1)
        {
         Print(__FUNCTION__, ": parámetros inválidos (ATR >= 1, multiplicador > 0, tolerancia >= 0, comparaciones >= 1)");
         return false;
        }
      if(!SymbolSelect(symbol, true))
        {
         Print(__FUNCTION__, ": símbolo no disponible '", symbol, "', code=", GetLastError());
         return false;
        }

      m_symbol         = symbol;
      m_timeframe      = timeframe;
      m_lookback       = MathMax(lookbackBars, atrPeriod + TREND_DETECTOR_MIN_EXTRA_BARS);
      m_atrPeriod      = atrPeriod;
      m_atrMultiplier  = atrMultiplier;
      m_equalTolerance = equalTolerance;
      m_comparisons    = comparisons;
      return true;
     }

   //--- Recalcula sobre velas cerradas. Devuelve false si el historial aún no está disponible.
   bool              Update(void)
     {
      MqlRates rates[];
      int copied = CopyRates(m_symbol, m_timeframe, 1, m_lookback, rates);
      if(copied < m_atrPeriod + TREND_DETECTOR_MIN_EXTRA_BARS)
        {
         Print(__FUNCTION__, ": historial insuficiente para ", m_symbol, " ", TimeframeName(),
               " (", copied, " velas), code=", GetLastError());
         return false;
        }

      double atr[];
      ComputeAtr(rates, m_atrPeriod, atr);
      BuildZigZag(rates, atr);

      m_lastClose = rates[copied - 1].close;
      Classify();
      return true;
     }

   ENUM_MARKET_TREND Trend(void) const { return m_trend; }
   string            Reason(void) const { return m_reason; }
   string            AnalyzedSymbol(void) const { return m_symbol; }
   ENUM_TIMEFRAMES   AnalyzedTimeframe(void) const { return m_timeframe; }
   string            TimeframeName(void) const { return StringSubstr(EnumToString(m_timeframe), 7); }
   int               PivotCount(void) const { return ArraySize(m_pivots); }
   STrendPivot       Pivot(int index) const { return m_pivots[index]; }

   static string     TrendToString(ENUM_MARKET_TREND trend)
     {
      switch(trend)
        {
         case TREND_BULLISH:
            return "ALCISTA";
         case TREND_BEARISH:
            return "BAJISTA";
         default:
            return "LATERAL";
        }
     }

   static string     PivotLabel(const STrendPivot &pivot)
     {
      switch(pivot.relation)
        {
         case PIVOT_HIGHER:
            return pivot.isHigh ? "HH" : "HL";
         case PIVOT_LOWER:
            return pivot.isHigh ? "LH" : "LL";
         case PIVOT_EQUAL:
            return pivot.isHigh ? "EQH" : "EQL";
         default:
            return pivot.isHigh ? "H" : "L";
        }
     }
  };

#endif // TREND_DETECTOR_MQH
