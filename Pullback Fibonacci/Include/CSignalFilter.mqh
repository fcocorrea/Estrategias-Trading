//+------------------------------------------------------------------+
//|                                               CSignalFilter.mqh |
//|  Capa obligatoria previa a cualquier entrada (regla por defecto  |
//|  del estándar de EAs): volumen > promedio 20 velas + RSI         |
//|  direccional (no comprar en sobrecompra, no vender en sobreventa)|
//+------------------------------------------------------------------+
#ifndef FIBEA_SIGNAL_FILTER_MQH
#define FIBEA_SIGNAL_FILTER_MQH

class CSignalFilter
  {
private:
   int               m_rsiHandle;
   int               m_volumePeriod;
   double            m_rsiOverbought;
   double            m_rsiOversold;

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

   //--- Promedio de volumen de las 'period' velas previas a 'shift' (excluye 'shift')
   bool              GetAverageVolume(int shift, int period, double &avgOut)
     {
      long volumeBuffer[];
      ArraySetAsSeries(volumeBuffer, true);

      if(CopyTickVolume(_Symbol, _Period, shift + 1, period, volumeBuffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando volumen promedio, code=", GetLastError());
         return false;
        }

      long sum   = 0;
      int  count = ArraySize(volumeBuffer);
      if(count == 0)
         return false;

      for(int i = 0; i < count; i++)
         sum += volumeBuffer[i];

      avgOut = (double)sum / (double)count;
      return true;
     }

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
                     CSignalFilter(void) : m_rsiHandle(INVALID_HANDLE), m_volumePeriod(20),
                                            m_rsiOverbought(70.0), m_rsiOversold(30.0) {}

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

   //--- Regla obligatoria 1: volumen de la última vela cerrada > promedio de las N previas
   bool              IsVolumeConfirmed(void)
     {
      long   lastVolume = 0;
      double avgVolume  = 0.0;

      if(!GetVolume(1, lastVolume))              return false;
      if(!GetAverageVolume(1, m_volumePeriod, avgVolume)) return false;

      return(double)lastVolume > avgVolume;
     }

   //--- Regla obligatoria 2: filtro RSI direccional (no comprar en sobrecompra,
   //--- no vender en sobreventa; lo inverso sí está permitido).
   bool              IsRsiAllowed(int direction)
     {
      double rsi = 0.0;
      if(!GetRsi(1, rsi))
         return false;

      if(direction == 1 && rsi >= m_rsiOverbought) return false;
      if(direction == -1 && rsi <= m_rsiOversold)  return false;

      return true;
     }

   //--- Filtro combinado obligatorio, a llamar con la dirección ya definida por la señal
   bool              IsAllowedToTrade(int direction)
     {
      return IsVolumeConfirmed() && IsRsiAllowed(direction);
     }
  };

#endif // FIBEA_SIGNAL_FILTER_MQH
