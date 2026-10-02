//+------------------------------------------------------------------+
//|                                       CConfirmationSignal.mqh |
//|  Confirmación de entrada tras el retroceso a zona de Fibonacci:  |
//|  patrón de velas, cruce de EMAs rápidas o divergencia de RSI     |
//|  (basta con que se cumpla UNA de las habilitadas).                |
//+------------------------------------------------------------------+
#ifndef FIBEA_CONFIRMATION_SIGNAL_MQH
#define FIBEA_CONFIRMATION_SIGNAL_MQH

#include "CSwingDetector.mqh"

class CConfirmationSignal
  {
private:
   bool              m_useCandlePattern;
   bool              m_useEmaCross;
   bool              m_useRsiDivergence;

   int               m_fastEmaHandle;
   int               m_slowEmaHandle;
   int               m_rsiHandle;

   bool              GetOhlc(int shift, double &o, double &h, double &l, double &c)
     {
      double openBuf[], highBuf[], lowBuf[], closeBuf[];
      ArraySetAsSeries(openBuf, true);
      ArraySetAsSeries(highBuf, true);
      ArraySetAsSeries(lowBuf, true);
      ArraySetAsSeries(closeBuf, true);

      if(CopyOpen(_Symbol, _Period, shift, 1, openBuf) <= 0)   return false;
      if(CopyHigh(_Symbol, _Period, shift, 1, highBuf) <= 0)   return false;
      if(CopyLow(_Symbol, _Period, shift, 1, lowBuf) <= 0)     return false;
      if(CopyClose(_Symbol, _Period, shift, 1, closeBuf) <= 0) return false;

      o = openBuf[0]; h = highBuf[0]; l = lowBuf[0]; c = closeBuf[0];
      return true;
     }

   bool              RsiAt(int shift, double &value)
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_rsiHandle, 0, shift, 1, buf) <= 0)
         return false;
      value = buf[0];
      return true;
     }

public:
                     CConfirmationSignal(void) : m_useCandlePattern(true), m_useEmaCross(true),
                                                  m_useRsiDivergence(true), m_fastEmaHandle(INVALID_HANDLE),
                                                  m_slowEmaHandle(INVALID_HANDLE), m_rsiHandle(INVALID_HANDLE) {}

   bool              Init(bool useCandlePattern, bool useEmaCross, bool useRsiDivergence,
                           int fastEmaPeriod, int slowEmaPeriod, int rsiPeriod)
     {
      m_useCandlePattern = useCandlePattern;
      m_useEmaCross      = useEmaCross;
      m_useRsiDivergence = useRsiDivergence;

      if(!m_useCandlePattern && !m_useEmaCross && !m_useRsiDivergence)
        {
         Print(__FUNCTION__, ": ninguna confirmacion habilitada, se exige al menos una");
         return false;
        }

      if(m_useEmaCross)
        {
         m_fastEmaHandle = iMA(_Symbol, _Period, fastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
         m_slowEmaHandle = iMA(_Symbol, _Period, slowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
         if(m_fastEmaHandle == INVALID_HANDLE || m_slowEmaHandle == INVALID_HANDLE)
           {
            Print(__FUNCTION__, ": no se pudo crear EMAs de confirmacion, code=", GetLastError());
            return false;
           }
        }

      if(m_useRsiDivergence)
        {
         m_rsiHandle = iRSI(_Symbol, _Period, rsiPeriod, PRICE_CLOSE);
         if(m_rsiHandle == INVALID_HANDLE)
           {
            Print(__FUNCTION__, ": no se pudo crear RSI de divergencia, code=", GetLastError());
            return false;
           }
        }

      return true;
     }

   void              Deinit(void)
     {
      if(m_fastEmaHandle != INVALID_HANDLE) IndicatorRelease(m_fastEmaHandle);
      if(m_slowEmaHandle != INVALID_HANDLE) IndicatorRelease(m_slowEmaHandle);
      if(m_rsiHandle     != INVALID_HANDLE) IndicatorRelease(m_rsiHandle);
     }

   //--- Envolvente alcista, martillo o pin bar alcista (mecha inferior larga, cuerpo pequeño)
   bool              IsBullishReversalCandle(void)
     {
      double o1, h1, l1, c1, o2, h2, l2, c2;
      if(!GetOhlc(1, o1, h1, l1, c1)) return false;
      if(!GetOhlc(2, o2, h2, l2, c2)) return false;

      bool bullishEngulfing = (c2 < o2) && (c1 > o1) && (o1 <= c2) && (c1 >= o2);

      double body      = MathAbs(c1 - o1);
      double range      = h1 - l1;
      double lowerWick = MathMin(o1, c1) - l1;
      double upperWick = h1 - MathMax(o1, c1);
      bool hammerOrPin = (range > 0.0) && (lowerWick >= body * 2.0) &&
                         (upperWick <= body * 0.5 || body <= range * 0.1);

      return(bullishEngulfing || hammerOrPin);
     }

   //--- Envolvente bajista, estrella fugaz o pin bar bajista (mecha superior larga)
   bool              IsBearishReversalCandle(void)
     {
      double o1, h1, l1, c1, o2, h2, l2, c2;
      if(!GetOhlc(1, o1, h1, l1, c1)) return false;
      if(!GetOhlc(2, o2, h2, l2, c2)) return false;

      bool bearishEngulfing = (c2 > o2) && (c1 < o1) && (o1 >= c2) && (c1 <= o2);

      double body      = MathAbs(c1 - o1);
      double range      = h1 - l1;
      double upperWick = h1 - MathMax(o1, c1);
      double lowerWick = MathMin(o1, c1) - l1;
      bool shootingOrPin = (range > 0.0) && (upperWick >= body * 2.0) &&
                           (lowerWick <= body * 0.5 || body <= range * 0.1);

      return(bearishEngulfing || shootingOrPin);
     }

   bool              IsBullishEmaCross(void)
     {
      if(m_fastEmaHandle == INVALID_HANDLE) return false;

      double fast[], slow[];
      ArraySetAsSeries(fast, true);
      ArraySetAsSeries(slow, true);
      if(CopyBuffer(m_fastEmaHandle, 0, 1, 2, fast) <= 0) return false;
      if(CopyBuffer(m_slowEmaHandle, 0, 1, 2, slow) <= 0) return false;

      // fast[0]/slow[0] = última vela cerrada, fast[1]/slow[1] = anterior
      return(fast[1] <= slow[1] && fast[0] > slow[0]);
     }

   bool              IsBearishEmaCross(void)
     {
      if(m_fastEmaHandle == INVALID_HANDLE) return false;

      double fast[], slow[];
      ArraySetAsSeries(fast, true);
      ArraySetAsSeries(slow, true);
      if(CopyBuffer(m_fastEmaHandle, 0, 1, 2, fast) <= 0) return false;
      if(CopyBuffer(m_slowEmaHandle, 0, 1, 2, slow) <= 0) return false;

      return(fast[1] >= slow[1] && fast[0] < slow[0]);
     }

   //--- Divergencia alcista: precio hace mínimo más bajo mientras el RSI hace mínimo más alto
   bool              IsBullishRsiDivergence(SFibSwingPoint &lows[])
     {
      if(m_rsiHandle == INVALID_HANDLE || ArraySize(lows) < 2) return false;

      double rsiRecent, rsiPrev;
      if(!RsiAt(lows[0].shift, rsiRecent)) return false;
      if(!RsiAt(lows[1].shift, rsiPrev))   return false;

      return(lows[0].price < lows[1].price && rsiRecent > rsiPrev);
     }

   //--- Divergencia bajista: precio hace máximo más alto mientras el RSI hace máximo más bajo
   bool              IsBearishRsiDivergence(SFibSwingPoint &highs[])
     {
      if(m_rsiHandle == INVALID_HANDLE || ArraySize(highs) < 2) return false;

      double rsiRecent, rsiPrev;
      if(!RsiAt(highs[0].shift, rsiRecent)) return false;
      if(!RsiAt(highs[1].shift, rsiPrev))   return false;

      return(highs[0].price > highs[1].price && rsiRecent < rsiPrev);
     }

   //--- OR lógico entre las confirmaciones habilitadas, en la dirección de la señal
   bool              IsConfirmed(int direction, SFibSwingPoint &highs[], SFibSwingPoint &lows[])
     {
      if(direction == 1)
        {
         if(m_useCandlePattern && IsBullishReversalCandle())    return true;
         if(m_useEmaCross      && IsBullishEmaCross())          return true;
         if(m_useRsiDivergence && IsBullishRsiDivergence(lows)) return true;
         return false;
        }

      if(direction == -1)
        {
         if(m_useCandlePattern && IsBearishReversalCandle())     return true;
         if(m_useEmaCross      && IsBearishEmaCross())           return true;
         if(m_useRsiDivergence && IsBearishRsiDivergence(highs)) return true;
         return false;
        }

      return false;
     }
  };

#endif // FIBEA_CONFIRMATION_SIGNAL_MQH
