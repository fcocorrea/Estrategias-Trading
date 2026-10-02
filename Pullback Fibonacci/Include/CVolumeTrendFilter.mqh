//+------------------------------------------------------------------+
//|                                          CVolumeTrendFilter.mqh |
//|  Filtro adicional de la estrategia: el volumen debe disminuir    |
//|  durante el retroceso frente al del impulso previo (la subida    |
//|  de volumen en la vela de confirmación ya la exige CSignalFilter)|
//+------------------------------------------------------------------+
#ifndef FIBEA_VOLUME_TREND_FILTER_MQH
#define FIBEA_VOLUME_TREND_FILTER_MQH

class CVolumeTrendFilter
  {
public:
   static bool       IsPullbackVolumeDecreasing(int impulseStartShift, int impulseEndShift, int pullbackBars)
     {
      int impulseFrom  = MathMin(impulseStartShift, impulseEndShift);
      int impulseCount = MathAbs(impulseStartShift - impulseEndShift) + 1;
      if(impulseCount <= 0 || pullbackBars <= 0)
         return false;

      long impulseVol[], pullbackVol[];
      ArraySetAsSeries(impulseVol, true);
      ArraySetAsSeries(pullbackVol, true);

      if(CopyTickVolume(_Symbol, _Period, impulseFrom, impulseCount, impulseVol) <= 0)
         return false;
      if(CopyTickVolume(_Symbol, _Period, 1, pullbackBars, pullbackVol) <= 0)
         return false;

      double avgImpulse = 0.0, avgPullback = 0.0;
      for(int i = 0; i < ArraySize(impulseVol); i++)
         avgImpulse += (double)impulseVol[i];
      avgImpulse /= ArraySize(impulseVol);

      for(int i = 0; i < ArraySize(pullbackVol); i++)
         avgPullback += (double)pullbackVol[i];
      avgPullback /= ArraySize(pullbackVol);

      return avgPullback < avgImpulse;
     }
  };

#endif // FIBEA_VOLUME_TREND_FILTER_MQH
