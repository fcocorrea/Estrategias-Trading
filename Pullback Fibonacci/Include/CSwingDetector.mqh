//+------------------------------------------------------------------+
//|                                              CSwingDetector.mqh |
//|  Detecta pivotes (fractales de 5 velas) y el último impulso      |
//|  (swing origen -> swing destino) sobre el que se traza el        |
//|  retroceso de Fibonacci.                                         |
//+------------------------------------------------------------------+
#ifndef FIBEA_SWING_DETECTOR_MQH
#define FIBEA_SWING_DETECTOR_MQH

//--- Punto de pivote (fractal) detectado en el gráfico
struct SFibSwingPoint
  {
   int      shift;   // desplazamiento respecto a la vela actual (1 = última cerrada)
   datetime time;
   double   price;
  };

class CSwingDetector
  {
private:
   int               m_lookback;

   //--- Fractal clásico de 5 velas: el centro supera a sus 2 vecinos a cada lado
   static bool       IsFractalHigh(const double &high[], int idx, int size)
     {
      if(idx - 2 < 0 || idx + 2 >= size)
         return false;
      return(high[idx] > high[idx - 1] && high[idx] > high[idx - 2] &&
             high[idx] > high[idx + 1] && high[idx] > high[idx + 2]);
     }

   static bool       IsFractalLow(const double &low[], int idx, int size)
     {
      if(idx - 2 < 0 || idx + 2 >= size)
         return false;
      return(low[idx] < low[idx - 1] && low[idx] < low[idx - 2] &&
             low[idx] < low[idx + 1] && low[idx] < low[idx + 2]);
     }

public:
                     CSwingDetector(void) : m_lookback(150) {}

   void              Init(int lookbackBars) { m_lookback = MathMax(lookbackBars, 20); }

   //--- Recolecta los fractales de máximos y mínimos en la ventana [1, lookback].
   //--- Los arrays quedan ordenados del pivote más reciente (shift menor) al más antiguo.
   bool              CollectPivots(SFibSwingPoint &highs[], SFibSwingPoint &lows[])
     {
      double   highBuf[], lowBuf[];
      datetime timeBuf[];
      ArraySetAsSeries(highBuf, true);
      ArraySetAsSeries(lowBuf, true);
      ArraySetAsSeries(timeBuf, true);

      if(CopyHigh(_Symbol, _Period, 1, m_lookback, highBuf) <= 0)
        {
         Print(__FUNCTION__, ": error copiando maximos, code=", GetLastError());
         return false;
        }
      if(CopyLow(_Symbol, _Period, 1, m_lookback, lowBuf) <= 0)
        {
         Print(__FUNCTION__, ": error copiando minimos, code=", GetLastError());
         return false;
        }
      if(CopyTime(_Symbol, _Period, 1, m_lookback, timeBuf) <= 0)
        {
         Print(__FUNCTION__, ": error copiando tiempos, code=", GetLastError());
         return false;
        }

      int size = ArraySize(highBuf);
      ArrayResize(highs, 0);
      ArrayResize(lows, 0);

      for(int i = 0; i < size; i++)
        {
         if(IsFractalHigh(highBuf, i, size))
           {
            int n = ArraySize(highs);
            ArrayResize(highs, n + 1);
            highs[n].shift = i + 1; // +1: el buffer arranca en shift 1 (última vela cerrada)
            highs[n].time  = timeBuf[i];
            highs[n].price = highBuf[i];
           }
         if(IsFractalLow(lowBuf, i, size))
           {
            int n = ArraySize(lows);
            ArrayResize(lows, n + 1);
            lows[n].shift = i + 1;
            lows[n].time  = timeBuf[i];
            lows[n].price = lowBuf[i];
           }
        }

      return(ArraySize(highs) > 0 && ArraySize(lows) > 0);
     }

   //--- Último impulso en la dirección de la tendencia:
   //--- alcista  -> desde el mínimo más reciente hasta el máximo más reciente
   //--- bajista  -> desde el máximo más reciente hasta el mínimo más reciente
   static bool       GetLastImpulse(int trend, SFibSwingPoint &highs[], SFibSwingPoint &lows[],
                                     SFibSwingPoint &startPoint, SFibSwingPoint &endPoint)
     {
      if(ArraySize(highs) == 0 || ArraySize(lows) == 0)
         return false;

      if(trend == 1)
        {
         SFibSwingPoint recentHigh = highs[0];
         for(int i = 0; i < ArraySize(lows); i++)
           {
            if(lows[i].shift > recentHigh.shift) // mínimo previo al máximo (origen del impulso)
              {
               startPoint = lows[i];
               endPoint   = recentHigh;
               return true;
              }
           }
         return false;
        }

      if(trend == -1)
        {
         SFibSwingPoint recentLow = lows[0];
         for(int i = 0; i < ArraySize(highs); i++)
           {
            if(highs[i].shift > recentLow.shift) // máximo previo al mínimo (origen del impulso)
              {
               startPoint = highs[i];
               endPoint   = recentLow;
               return true;
              }
           }
         return false;
        }

      return false;
     }

   //--- Estructura de mercado: máximos y mínimos crecientes (alcista) o decrecientes (bajista)
   static bool       HasTrendStructure(int trend, SFibSwingPoint &highs[], SFibSwingPoint &lows[])
     {
      if(ArraySize(highs) < 2 || ArraySize(lows) < 2)
         return false;

      if(trend == 1)
         return(highs[0].price > highs[1].price && lows[0].price > lows[1].price);
      if(trend == -1)
         return(highs[0].price < highs[1].price && lows[0].price < lows[1].price);

      return false;
     }
  };

#endif // FIBEA_SWING_DETECTOR_MQH
