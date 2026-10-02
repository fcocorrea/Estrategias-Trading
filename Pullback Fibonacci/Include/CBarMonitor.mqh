//+------------------------------------------------------------------+
//|                                                 CBarMonitor.mqh |
//|      Detecta el cierre de una vela nueva (regla: solo al cierre) |
//+------------------------------------------------------------------+
#ifndef FIBEA_BAR_MONITOR_MQH
#define FIBEA_BAR_MONITOR_MQH

class CBarMonitor
  {
private:
   datetime          m_lastBarTime;

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

#endif // FIBEA_BAR_MONITOR_MQH
