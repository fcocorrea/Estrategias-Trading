//+------------------------------------------------------------------+
//|                                                CTrendFilter.mqh |
//|  Confirma tendencia: precio vs EMA + estructura de máximos y     |
//|  mínimos (crecientes/decrecientes).                              |
//+------------------------------------------------------------------+
#ifndef FIBEA_TREND_FILTER_MQH
#define FIBEA_TREND_FILTER_MQH

#include "CSwingDetector.mqh"

class CTrendFilter
  {
private:
   int               m_emaHandle;
   bool              m_requireStructure;

public:
                     CTrendFilter(void) : m_emaHandle(INVALID_HANDLE), m_requireStructure(true) {}

   bool              Init(int emaPeriod, bool requireStructure)
     {
      m_requireStructure = requireStructure;

      m_emaHandle = iMA(_Symbol, _Period, emaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(m_emaHandle == INVALID_HANDLE)
        {
         Print(__FUNCTION__, ": no se pudo crear el handle de EMA de tendencia, code=", GetLastError());
         return false;
        }

      return true;
     }

   void              Deinit(void)
     {
      if(m_emaHandle != INVALID_HANDLE)
         IndicatorRelease(m_emaHandle);
     }

   //--- Devuelve 1 (alcista), -1 (bajista) o 0 (sin tendencia clara), evaluado
   //--- sobre el cierre de la última vela cerrada.
   int               GetTrend(SFibSwingPoint &highs[], SFibSwingPoint &lows[])
     {
      double emaBuf[], closeBuf[];
      ArraySetAsSeries(emaBuf, true);
      ArraySetAsSeries(closeBuf, true);

      if(CopyBuffer(m_emaHandle, 0, 1, 1, emaBuf) <= 0)
        {
         Print(__FUNCTION__, ": error copiando EMA de tendencia, code=", GetLastError());
         return 0;
        }
      if(CopyClose(_Symbol, _Period, 1, 1, closeBuf) <= 0)
        {
         Print(__FUNCTION__, ": error copiando cierre, code=", GetLastError());
         return 0;
        }

      int trend = 0;
      if(closeBuf[0] > emaBuf[0])
         trend = 1;
      else
         if(closeBuf[0] < emaBuf[0])
            trend = -1;

      if(trend == 0)
         return 0;

      if(m_requireStructure && !CSwingDetector::HasTrendStructure(trend, highs, lows))
         return 0;

      return trend;
     }
  };

#endif // FIBEA_TREND_FILTER_MQH
