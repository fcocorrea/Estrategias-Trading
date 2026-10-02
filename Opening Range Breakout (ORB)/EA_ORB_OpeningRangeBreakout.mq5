//+------------------------------------------------------------------+
//|                              EA_ORB_OpeningRangeBreakout.mq5     |
//| EA de Ruptura del Rango de Apertura (Opening Range Breakout).    |
//| Estrategia documentada en Estrategia_ORB_Opening_Range_Breakout.md|
//|                                                                    |
//| - Rango: máximo/mínimo de una vela de la temporalidad de rango    |
//|   (anterior o actual respecto de la hora de operación).           |
//| - Confirmación: setups evaluados solo sobre velas cerradas de la  |
//|   temporalidad de confirmación (Breakout, Liquidity Sweep, FVG).  |
//| - Horario en hora de Nueva York (con horario de verano) o del     |
//|   servidor; cierre forzado antes del fin de sesión (sin overnight).|
//| - Riesgo: lotaje fijo o % de riesgo, TP por RR o measured move,   |
//|   cierre parcial con break even opcional.                         |
//+------------------------------------------------------------------+
#property copyright "Robots AE"
#property version   "2.00"

#include <Trade\Trade.mqh>

enum ENUM_ORB_SETUP
  {
   ORB_SETUP_BREAKOUT        = 0, // Ruptura limpia (cierre fuera del rango)
   ORB_SETUP_LIQUIDITY_SWEEP = 1, // Liquidity Sweep (rompe con cuerpo y reingresa -> contra la ruptura)
   ORB_SETUP_FVG             = 2  // FVG de ruptura (rompe, rellena el gap y continúa -> a favor)
  };

enum ENUM_ORB_RANGE_CANDLE
  {
   ORB_RANGE_PREVIOUS = 0, // Vela anterior (última vela cerrada antes de la hora de operación)
   ORB_RANGE_CURRENT  = 1  // Vela actual (vela en curso a la hora de operación)
  };

enum ENUM_ORB_TIME_REFERENCE
  {
   ORB_TIME_NEW_YORK = 0, // Hora de Nueva York (ET, con horario de verano)
   ORB_TIME_SERVER   = 1  // Hora del servidor del bróker
  };

enum ENUM_ORB_SERVER_DST
  {
   ORB_DST_NONE = 0, // Sin horario de verano
   ORB_DST_US   = 1, // Horario de verano de EE.UU.
   ORB_DST_EU   = 2  // Horario de verano europeo
  };

enum ENUM_ORB_SL_MODE
  {
   ORB_SL_STRUCTURE = 0, // Estructura del setup (lado opuesto / extremo del sweep / origen del FVG)
   ORB_SL_MIDPOINT  = 1  // Punto medio del rango (Breakout y FVG; el Sweep usa estructura)
  };

enum ENUM_ORB_TP_MODE
  {
   ORB_TP_NONE           = 0, // Sin TP (salida por cierre de sesión)
   ORB_TP_RISK_REWARD    = 1, // Ratio riesgo/beneficio (RR)
   ORB_TP_RANGE_MULTIPLE = 2  // Altura del rango x múltiplo (measured move)
  };

input group "=== General ==="
input int                     InpMagicNumber          = 202608;              // Magic number
input int                     InpSlippage             = 10;                  // Slippage en puntos

input group "=== Rango y confirmación ==="
input ENUM_TIMEFRAMES         InpRangeTimeframe       = PERIOD_M30;          // Temporalidad del rango (ej. M15, M30, H1, D1)
input ENUM_TIMEFRAMES         InpConfirmTimeframe     = PERIOD_M5;           // Temporalidad de confirmación (<= rango)
input ENUM_ORB_RANGE_CANDLE   InpRangeCandle          = ORB_RANGE_CURRENT;   // Vela de rango: anterior o actual
input ENUM_ORB_SETUP          InpSetup                = ORB_SETUP_LIQUIDITY_SWEEP; // Estrategia de entrada
input double                  InpMinRangePoints       = 0;                   // Ancho mínimo del rango en puntos (0 = sin filtro)
input int                     InpSweepMaxBars         = 3;                   // Sweep: máx. velas fuera del rango antes de reingresar (0 = sin límite)
input int                     InpFvgMaxBars           = 10;                  // FVG: máx. velas para formar el gap y para confirmar (0 = sin límite)

input group "=== Horario de operación ==="
input ENUM_ORB_TIME_REFERENCE InpTimeReference        = ORB_TIME_NEW_YORK;   // Zona horaria de los horarios
input int                     InpTradeStartHour       = 9;                   // Hora de inicio de búsqueda (apertura NY = 9:30)
input int                     InpTradeStartMinute     = 30;                  // Minuto de inicio de búsqueda
input int                     InpTradeEndHour         = 12;                  // Hora límite para nuevas entradas
input int                     InpTradeEndMinute       = 0;                   // Minuto límite para nuevas entradas
input bool                    InpForceSessionClose    = true;                // Cerrar posiciones antes del fin de sesión (sin overnight)
input int                     InpSessionCloseHour     = 15;                  // Hora de cierre forzado
input int                     InpSessionCloseMinute   = 45;                  // Minuto de cierre forzado
input int                     InpServerGmtOffset      = 0;                   // Offset GMT del servidor en invierno (horas; Exness = 0)
input ENUM_ORB_SERVER_DST     InpServerDst            = ORB_DST_NONE;        // Horario de verano del servidor (Exness = sin DST)
input int                     InpMaxTradesPerDay      = 1;                   // Máximo de operaciones por día (recomendado 1-2)

input group "=== Gestión de riesgo ==="
input bool                    InpUseMoneyManagement   = true;                // true = lotaje por % de riesgo, false = lotaje fijo
input double                  InpRiskPercent          = 1.0;                 // % de balance arriesgado por operación
input double                  InpFixedLots            = 0.10;                // Lotaje fijo (si MM = false)
input ENUM_ORB_SL_MODE        InpSlMode               = ORB_SL_STRUCTURE;    // Modo de stop loss
input double                  InpSlBufferPoints       = 0;                   // Margen adicional del stop en puntos
input ENUM_ORB_TP_MODE        InpTpMode               = ORB_TP_RISK_REWARD;  // Modo de take profit
input double                  InpRiskReward           = 2.0;                 // Ratio RR (TP = riesgo x RR)
input double                  InpRangeTpMultiplier    = 1.0;                 // TP = altura del rango x este múltiplo
input bool                    InpUsePartialClose      = false;               // Activar cierre parcial
input double                  InpPartialAtR           = 1.0;                 // Cierre parcial al alcanzar X veces el riesgo (R)
input double                  InpPartialPercent       = 50.0;                // % del volumen a cerrar en el parcial
input bool                    InpBreakEvenAfterPartial = true;               // Mover el stop a break even tras el parcial

input group "=== Filtros ==="
input bool                    InpUseVolumeFilter      = true;                // Exigir volumen de la vela de señal > promedio
input int                     InpVolumePeriod         = 20;                  // Velas para el promedio de volumen
input bool                    InpUseRsiFilter         = true;                // No comprar en sobrecompra ni vender en sobreventa
input int                     InpRsiPeriod            = 14;                  // Período del RSI
input double                  InpRsiOverbought        = 70.0;                // Nivel de sobrecompra
input double                  InpRsiOversold          = 30.0;                // Nivel de sobreventa

//+------------------------------------------------------------------+
//| CTimeZone: conversión hora de referencia (NY o servidor) <-> hora |
//| del servidor, que es la que usan las velas y TimeCurrent().       |
//| En el probador TimeGMT() no refleja el offset real del bróker,    |
//| por eso el offset del servidor se configura por input.            |
//+------------------------------------------------------------------+
class CTimeZone
  {
private:
   ENUM_ORB_TIME_REFERENCE m_reference;
   int               m_serverWinterOffset;
   ENUM_ORB_SERVER_DST m_serverDst;

   static datetime   NthSundayOfMonth(int year, int month, int nth)
     {
      MqlDateTime dt;
      ZeroMemory(dt);
      dt.year = year;
      dt.mon  = month;
      dt.day  = 1;

      MqlDateTime firstDay;
      TimeToStruct(StructToTime(dt), firstDay);

      dt.day = 1 + (7 - firstDay.day_of_week) % 7 + 7 * (nth - 1);
      return StructToTime(dt);
     }

   static datetime   LastSundayOfMonth(int year, int month)
     {
      MqlDateTime dt;
      ZeroMemory(dt);
      dt.year = (month == 12) ? year + 1 : year;
      dt.mon  = (month == 12) ? 1 : month + 1;
      dt.day  = 1;

      datetime lastDay = StructToTime(dt) - 86400;
      MqlDateTime lastDayStruct;
      TimeToStruct(lastDay, lastDayStruct);
      return lastDay - lastDayStruct.day_of_week * 86400;
     }

   //--- EE.UU.: 2º domingo de marzo 02:00 EST -> 1er domingo de noviembre 02:00 EDT
   static bool       IsUsDst(datetime utc)
     {
      MqlDateTime dt;
      TimeToStruct(utc, dt);
      datetime start = NthSundayOfMonth(dt.year, 3, 2)  + 7 * 3600;
      datetime end   = NthSundayOfMonth(dt.year, 11, 1) + 6 * 3600;
      return utc >= start && utc < end;
     }

   //--- UE: último domingo de marzo 01:00 UTC -> último domingo de octubre 01:00 UTC
   static bool       IsEuDst(datetime utc)
     {
      MqlDateTime dt;
      TimeToStruct(utc, dt);
      datetime start = LastSundayOfMonth(dt.year, 3)  + 3600;
      datetime end   = LastSundayOfMonth(dt.year, 10) + 3600;
      return utc >= start && utc < end;
     }

   static int        NewYorkOffset(datetime utc) { return IsUsDst(utc) ? -4 * 3600 : -5 * 3600; }

   int               ServerOffset(datetime utc) const
     {
      bool dst = (m_serverDst == ORB_DST_US && IsUsDst(utc)) ||
                 (m_serverDst == ORB_DST_EU && IsEuDst(utc));
      return m_serverWinterOffset + (dst ? 3600 : 0);
     }

public:
                     CTimeZone(void) : m_reference(ORB_TIME_NEW_YORK), m_serverWinterOffset(0), m_serverDst(ORB_DST_NONE) {}

   void              Init(ENUM_ORB_TIME_REFERENCE reference, int serverWinterOffsetHours, ENUM_ORB_SERVER_DST serverDst)
     {
      m_reference          = reference;
      m_serverWinterOffset = serverWinterOffsetHours * 3600;
      m_serverDst          = serverDst;
     }

   //--- El UTC se aproxima con el offset de invierno; solo difiere del exacto
   //--- durante la hora del cambio de horario (madrugada del domingo, mercado cerrado).
   datetime          ServerToReference(datetime server) const
     {
      if(m_reference == ORB_TIME_SERVER)
         return server;

      datetime utc = server - ServerOffset(server - m_serverWinterOffset);
      return utc + NewYorkOffset(utc);
     }

   datetime          ReferenceToServer(datetime reference) const
     {
      if(m_reference == ORB_TIME_SERVER)
         return reference;

      datetime utc = reference - NewYorkOffset(reference + 5 * 3600);
      return utc + ServerOffset(utc);
     }

   void              WarnIfServerOffsetMismatch(void) const
     {
      if(m_reference == ORB_TIME_SERVER || MQLInfoInteger(MQL_TESTER))
         return;

      datetime gmt      = TimeGMT();
      int      actual   = (int)MathRound((double)(TimeTradeServer() - gmt) / 1800.0) * 1800;
      int      expected = ServerOffset(gmt);
      if(actual != expected)
         PrintFormat("ADVERTENCIA ORB: offset GMT del servidor configurado (%+.1f h) distinto del real (%+.1f h). "
                     "Revise InpServerGmtOffset / InpServerDst o los horarios en NY serán incorrectos.",
                     expected / 3600.0, actual / 3600.0);
     }
  };

//+------------------------------------------------------------------+
//| CTradingSchedule: horarios del día de operación en hora servidor  |
//+------------------------------------------------------------------+
class CTradingSchedule
  {
private:
   CTimeZone         m_timeZone;
   int               m_startMinutes;
   int               m_endMinutes;
   int               m_closeMinutes;
   bool              m_forceClose;

   datetime          m_referenceDay;
   datetime          m_dayStart;
   datetime          m_tradeStart;
   datetime          m_tradeEnd;
   datetime          m_sessionClose;

   static datetime   DayStartOf(datetime t)
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      dt.hour = 0;
      dt.min  = 0;
      dt.sec  = 0;
      return StructToTime(dt);
     }

   static bool       IsValidTime(int hour, int minute) { return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59; }

public:
                     CTradingSchedule(void) : m_startMinutes(0), m_endMinutes(0), m_closeMinutes(0), m_forceClose(true),
                                              m_referenceDay(0), m_dayStart(0), m_tradeStart(0), m_tradeEnd(0), m_sessionClose(0) {}

   bool              Init(ENUM_ORB_TIME_REFERENCE reference, int serverWinterOffsetHours, ENUM_ORB_SERVER_DST serverDst,
                          int startHour, int startMinute, int endHour, int endMinute,
                          bool forceClose, int closeHour, int closeMinute)
     {
      if(!IsValidTime(startHour, startMinute) || !IsValidTime(endHour, endMinute) || !IsValidTime(closeHour, closeMinute))
        {
         Print(__FUNCTION__, ": horario fuera de rango (hora 0-23, minuto 0-59)");
         return false;
        }

      m_startMinutes = startHour * 60 + startMinute;
      m_endMinutes   = endHour * 60 + endMinute;
      m_closeMinutes = closeHour * 60 + closeMinute;
      m_forceClose   = forceClose;

      if(m_endMinutes <= m_startMinutes)
        {
         Print(__FUNCTION__, ": la hora límite de entradas debe ser posterior a la hora de inicio");
         return false;
        }
      if(m_forceClose && m_closeMinutes < m_endMinutes)
        {
         Print(__FUNCTION__, ": el cierre forzado debe ser igual o posterior a la hora límite de entradas");
         return false;
        }

      m_timeZone.Init(reference, serverWinterOffsetHours, serverDst);
      m_timeZone.WarnIfServerOffsetMismatch();
      return true;
     }

   //--- Devuelve true cuando comienza un nuevo día de operación (en la zona de referencia).
   bool              Refresh(void)
     {
      datetime referenceDay = DayStartOf(m_timeZone.ServerToReference(TimeCurrent()));
      if(referenceDay == m_referenceDay)
         return false;

      m_referenceDay = referenceDay;
      m_dayStart     = m_timeZone.ReferenceToServer(referenceDay);
      m_tradeStart   = m_timeZone.ReferenceToServer(referenceDay + m_startMinutes * 60);
      m_tradeEnd     = m_timeZone.ReferenceToServer(referenceDay + m_endMinutes * 60);
      m_sessionClose = m_timeZone.ReferenceToServer(referenceDay + m_closeMinutes * 60);
      return true;
     }

   datetime          DayStart(void)   const { return m_dayStart; }
   datetime          TradeStart(void) const { return m_tradeStart; }
   datetime          TradeEnd(void)   const { return m_tradeEnd; }

   bool              IsPastSessionClose(void) const
     {
      return m_forceClose && m_sessionClose > 0 && TimeCurrent() >= m_sessionClose;
     }
  };

//+------------------------------------------------------------------+
//| CBarMonitor: detecta la apertura de una vela nueva en un TF dado  |
//+------------------------------------------------------------------+
class CBarMonitor
  {
private:
   ENUM_TIMEFRAMES   m_timeframe;
   datetime          m_lastBarTime;

public:
                     CBarMonitor(void) : m_timeframe(PERIOD_CURRENT), m_lastBarTime(0) {}

   void              Init(ENUM_TIMEFRAMES timeframe) { m_timeframe = timeframe; }

   bool              IsNewBar(void)
     {
      datetime currentBarTime = iTime(_Symbol, m_timeframe, 0);
      if(currentBarTime == 0 || currentBarTime == m_lastBarTime)
         return false;

      m_lastBarTime = currentBarTime;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| CSignalFilter: filtros de volumen + RSI sobre la vela de señal    |
//| (última vela cerrada de la temporalidad de confirmación).         |
//| No genera la dirección; solo autoriza o bloquea la del setup.     |
//+------------------------------------------------------------------+
class CSignalFilter
  {
private:
   ENUM_TIMEFRAMES   m_timeframe;
   bool              m_useVolume;
   bool              m_useRsi;
   int               m_rsiHandle;
   int               m_volumePeriod;
   double            m_rsiOverbought;
   double            m_rsiOversold;

   bool              IsVolumeConfirmed(void)
     {
      long volumeBuffer[];
      ArraySetAsSeries(volumeBuffer, true);

      int required = m_volumePeriod + 1;
      if(CopyTickVolume(_Symbol, m_timeframe, 1, required, volumeBuffer) != required)
        {
         Print(__FUNCTION__, ": error copiando volumen, code=", GetLastError());
         return false;
        }

      long sum = 0;
      for(int i = 1; i < required; i++)
         sum += volumeBuffer[i];

      double average = (double)sum / (double)m_volumePeriod;
      return (double)volumeBuffer[0] > average;
     }

   bool              IsRsiAllowed(int direction)
     {
      double rsiBuffer[];
      if(CopyBuffer(m_rsiHandle, 0, 1, 1, rsiBuffer) <= 0)
        {
         Print(__FUNCTION__, ": error copiando RSI, code=", GetLastError());
         return false;
        }

      double rsi = rsiBuffer[0];
      if(direction == 1 && rsi >= m_rsiOverbought)
         return false;
      if(direction == -1 && rsi <= m_rsiOversold)
         return false;

      return true;
     }

public:
                     CSignalFilter(void) : m_timeframe(PERIOD_CURRENT), m_useVolume(true), m_useRsi(true),
                                           m_rsiHandle(INVALID_HANDLE), m_volumePeriod(20),
                                           m_rsiOverbought(70.0), m_rsiOversold(30.0) {}

   bool              Init(ENUM_TIMEFRAMES timeframe, bool useVolume, int volumePeriod,
                          bool useRsi, int rsiPeriod, double rsiOverbought, double rsiOversold)
     {
      m_timeframe     = timeframe;
      m_useVolume     = useVolume;
      m_useRsi        = useRsi;
      m_volumePeriod  = volumePeriod;
      m_rsiOverbought = rsiOverbought;
      m_rsiOversold   = rsiOversold;

      if(m_useVolume && m_volumePeriod < 1)
        {
         Print(__FUNCTION__, ": el período de volumen debe ser >= 1");
         return false;
        }

      if(!m_useRsi)
         return true;

      m_rsiHandle = iRSI(_Symbol, m_timeframe, rsiPeriod, PRICE_CLOSE);
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
      m_rsiHandle = INVALID_HANDLE;
     }

   bool              IsAllowedToTrade(int direction)
     {
      if(m_useVolume && !IsVolumeConfirmed())
         return false;
      if(m_useRsi && !IsRsiAllowed(direction))
         return false;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| COrbRange: rango (máximo/mínimo) de la vela de la temporalidad de |
//| rango, anclado a la hora de inicio de operación del día.          |
//|                                                                    |
//| Vela anterior: última vela cerrada antes de la hora de operación  |
//|   (D1 -> máximo/mínimo del día previo). Operable desde esa hora.  |
//| Vela actual: vela en curso a la hora de operación.                |
//|   - Si abre justo a esa hora (M15/M30 a las 9:30 NY) se espera a  |
//|     su cierre: ORB clásico.                                        |
//|   - Si abrió antes (H4, D1) se usa el máximo/mínimo formado hasta |
//|     la hora de operación.                                          |
//+------------------------------------------------------------------+
class COrbRange
  {
private:
   ENUM_TIMEFRAMES   m_timeframe;
   ENUM_ORB_RANGE_CANDLE m_candle;
   double            m_minRangePoints;

   datetime          m_anchor;
   bool              m_ready;
   bool              m_discarded;
   double            m_high;
   double            m_low;
   datetime          m_readyTime;

   bool              GetFormedExtremes(datetime from, datetime to, double &high, double &low)
     {
      double highBuf[], lowBuf[];
      if(CopyHigh(_Symbol, PERIOD_M1, from, to - 1, highBuf) <= 0 ||
         CopyLow(_Symbol,  PERIOD_M1, from, to - 1, lowBuf)  <= 0)
        {
         Print(__FUNCTION__, ": error copiando velas M1 del rango, code=", GetLastError());
         return false;
        }

      high = highBuf[ArrayMaximum(highBuf)];
      low  = lowBuf[ArrayMinimum(lowBuf)];
      return true;
     }

public:
                     COrbRange(void) : m_timeframe(PERIOD_CURRENT), m_candle(ORB_RANGE_CURRENT), m_minRangePoints(0.0),
                                       m_anchor(0), m_ready(false), m_discarded(false),
                                       m_high(0.0), m_low(0.0), m_readyTime(0) {}

   void              Init(ENUM_TIMEFRAMES timeframe, ENUM_ORB_RANGE_CANDLE candle, double minRangePoints)
     {
      m_timeframe      = timeframe;
      m_candle         = candle;
      m_minRangePoints = minRangePoints;
     }

   void              Reset(datetime anchor)
     {
      m_anchor    = anchor;
      m_ready     = false;
      m_discarded = false;
      m_high      = 0.0;
      m_low       = 0.0;
      m_readyTime = 0;
     }

   void              Update(void)
     {
      if(m_ready || m_discarded || m_anchor == 0 || TimeCurrent() < m_anchor)
         return;

      int period = PeriodSeconds(m_timeframe);
      int shift  = iBarShift(_Symbol, m_timeframe, m_anchor, false);
      if(shift < 0)
         return;

      datetime barOpen = iTime(_Symbol, m_timeframe, shift);
      if(barOpen == 0)
         return;

      bool   barContainsAnchor = barOpen + period > m_anchor;
      double high = 0.0, low = 0.0;
      datetime readyTime = m_anchor;

      if(m_candle == ORB_RANGE_PREVIOUS)
        {
         int previousShift = barContainsAnchor ? shift + 1 : shift;
         high = iHigh(_Symbol, m_timeframe, previousShift);
         low  = iLow(_Symbol,  m_timeframe, previousShift);
        }
      else
        {
         if(!barContainsAnchor)
            return;

         if(barOpen == m_anchor)
           {
            if(shift < 1)
               return;
            high      = iHigh(_Symbol, m_timeframe, shift);
            low       = iLow(_Symbol,  m_timeframe, shift);
            readyTime = barOpen + period;
           }
         else if(!GetFormedExtremes(barOpen, m_anchor, high, low))
            return;
        }

      if(high <= 0.0 || low <= 0.0 || high <= low)
         return;

      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(m_minRangePoints > 0 && point > 0 && (high - low) / point < m_minRangePoints)
        {
         Print("ORB: rango del día demasiado angosto (", (high - low) / point, " pts), se descarta la sesión");
         m_discarded = true;
         return;
        }

      m_high      = high;
      m_low       = low;
      m_readyTime = readyTime;
      m_ready     = true;

      Print("ORB: rango construido (", EnumToString(m_timeframe), ", ",
            (m_candle == ORB_RANGE_PREVIOUS ? "vela anterior" : "vela actual"), "). High=", m_high,
            " Low=", m_low, " operable desde ", TimeToString(m_readyTime), " (hora servidor)");
     }

   bool              IsReady(void)   const { return m_ready; }
   double            High(void)      const { return m_high; }
   double            Low(void)       const { return m_low; }
   double            Height(void)    const { return m_high - m_low; }
   double            Mid(void)       const { return (m_high + m_low) / 2.0; }
   datetime          ReadyTime(void) const { return m_readyTime; }
  };

//+------------------------------------------------------------------+
//| SOrbSignal / COrbSetupDetector                                    |
//| Recorre en orden cronológico las velas cerradas de confirmación   |
//| desde que el rango está listo y reconstruye cada setup. Solo hay  |
//| señal si el setup se completa en la última vela cerrada, así el   |
//| resultado es idéntico tras reiniciar el EA a mitad de sesión.     |
//| rates[0] es la vela previa a la ventana (referencia de cruce).    |
//+------------------------------------------------------------------+
struct SOrbSignal
  {
   int               direction;   // 1 = compra, -1 = venta
   double            stopLevel;   // nivel estructural del stop, sin margen adicional
  };

class COrbSetupDetector
  {
private:
   enum ENUM_FVG_STATE
     {
      FVG_IDLE,
      FVG_BROKEN,
      FVG_GAP,
      FVG_FILLED
     };

   ENUM_ORB_SETUP    m_setup;
   int               m_sweepMaxBars;
   int               m_fvgMaxBars;

   //--- side = 1 opera sobre el máximo del rango, side = -1 sobre el mínimo.
   static bool       IsBeyond(int side, double price, double level) { return side == 1 ? price > level : price < level; }
   static double     Extreme(int side, const MqlRates &bar)         { return side == 1 ? bar.high : bar.low; }
   static double     MoreExtreme(int side, double a, double b)      { return side == 1 ? MathMax(a, b) : MathMin(a, b); }

   static bool       ClosesBeyond(int side, const MqlRates &rates[], int i, double level)
     {
      return IsBeyond(side, rates[i].close, level) && !IsBeyond(side, rates[i - 1].close, level);
     }

   static bool       IsDirectionalCandle(int side, const MqlRates &bar)
     {
      return side == 1 ? bar.close > bar.open : bar.close < bar.open;
     }

   //--- FVG alcista: low(c3) > high(c1); bajista: high(c3) < low(c1). c3 = rates[i].
   static bool       IsFvg(int side, const MqlRates &rates[], int i)
     {
      return IsBeyond(side, Extreme(-side, rates[i]), Extreme(side, rates[i - 2])) &&
             IsDirectionalCandle(side, rates[i - 1]);
     }

   bool              DetectBreakout(int side, const MqlRates &rates[], double level, double oppositeLevel, SOrbSignal &signal)
     {
      int last = ArraySize(rates) - 1;
      if(!ClosesBeyond(side, rates, last, level))
         return false;

      signal.direction = side;
      signal.stopLevel = oppositeLevel;
      return true;
     }

   //--- Ruptura con cuerpo (cierre fuera) y reingreso (cierre dentro): se opera contra la ruptura.
   bool              DetectLiquiditySweep(int side, const MqlRates &rates[], double level, SOrbSignal &signal)
     {
      int    last         = ArraySize(rates) - 1;
      int    breakIndex   = -1;
      double sweepExtreme = 0.0;

      for(int i = 1; i <= last; i++)
        {
         if(breakIndex < 0)
           {
            if(ClosesBeyond(side, rates, i, level))
              {
               breakIndex   = i;
               sweepExtreme = Extreme(side, rates[i]);
              }
            continue;
           }

         sweepExtreme = MoreExtreme(side, sweepExtreme, Extreme(side, rates[i]));
         if(IsBeyond(side, rates[i].close, level))
            continue;

         bool reenteredInTime = (m_sweepMaxBars == 0 || i - breakIndex <= m_sweepMaxBars);
         if(i == last && reenteredInTime)
           {
            signal.direction = -side;
            signal.stopLevel = sweepExtreme;
            return true;
           }
         breakIndex = -1;
        }

      return false;
     }

   //--- Ruptura que deja un FVG, retroceso que toca el gap y vela de continuación
   //--- que cierra de nuevo fuera del gap: se opera a favor de la ruptura.
   bool              DetectFvg(int side, const MqlRates &rates[], double level, SOrbSignal &signal)
     {
      int            last       = ArraySize(rates) - 1;
      ENUM_FVG_STATE state      = FVG_IDLE;
      int            breakIndex = -1;
      int            gapIndex   = -1;
      double         gapNear    = 0.0;
      double         gapFar     = 0.0;
      double         stopLevel  = 0.0;

      for(int i = 1; i <= last; i++)
        {
         if(state == FVG_IDLE)
           {
            if(ClosesBeyond(side, rates, i, level))
              {
               state      = FVG_BROKEN;
               breakIndex = i;
              }
            continue;
           }

         if(state == FVG_BROKEN)
           {
            if(!IsBeyond(side, rates[i].close, level))
               state = FVG_IDLE;
            else if(IsFvg(side, rates, i))
              {
               gapNear   = Extreme(-side, rates[i]);
               gapFar    = Extreme(side, rates[i - 2]);
               stopLevel = MoreExtreme(-side, Extreme(-side, rates[i - 2]), Extreme(-side, rates[i - 1]));
               gapIndex  = i;
               state     = FVG_GAP;
              }
            else if(m_fvgMaxBars > 0 && i - breakIndex >= m_fvgMaxBars)
               state = FVG_IDLE;
            continue;
           }

         stopLevel = MoreExtreme(-side, stopLevel, Extreme(-side, rates[i]));

         if(IsBeyond(-side, rates[i].close, gapFar))
           {
            state = FVG_IDLE;
            continue;
           }

         if(state == FVG_GAP && !IsBeyond(side, Extreme(-side, rates[i]), gapNear))
            state = FVG_FILLED;

         if(state == FVG_FILLED && IsDirectionalCandle(side, rates[i]) && IsBeyond(side, rates[i].close, gapNear))
           {
            if(i == last)
              {
               signal.direction = side;
               signal.stopLevel = stopLevel;
               return true;
              }
            state = FVG_IDLE;
            continue;
           }

         if(m_fvgMaxBars > 0 && i - gapIndex >= m_fvgMaxBars)
            state = FVG_IDLE;
        }

      return false;
     }

   bool              DetectSide(int side, const MqlRates &rates[], double rangeHigh, double rangeLow, SOrbSignal &signal)
     {
      double level         = side == 1 ? rangeHigh : rangeLow;
      double oppositeLevel = side == 1 ? rangeLow  : rangeHigh;

      switch(m_setup)
        {
         case ORB_SETUP_BREAKOUT:
            return DetectBreakout(side, rates, level, oppositeLevel, signal);
         case ORB_SETUP_LIQUIDITY_SWEEP:
            return DetectLiquiditySweep(side, rates, level, signal);
         case ORB_SETUP_FVG:
            return DetectFvg(side, rates, level, signal);
        }
      return false;
     }

public:
                     COrbSetupDetector(void) : m_setup(ORB_SETUP_BREAKOUT), m_sweepMaxBars(0), m_fvgMaxBars(0) {}

   void              Init(ENUM_ORB_SETUP setup, int sweepMaxBars, int fvgMaxBars)
     {
      m_setup        = setup;
      m_sweepMaxBars = sweepMaxBars;
      m_fvgMaxBars   = fvgMaxBars;
     }

   bool              Evaluate(const MqlRates &rates[], double rangeHigh, double rangeLow, SOrbSignal &signal)
     {
      if(ArraySize(rates) < 2)
         return false;

      SOrbSignal highSide, lowSide;
      ZeroMemory(highSide);
      ZeroMemory(lowSide);

      bool fromHigh = DetectSide(1,  rates, rangeHigh, rangeLow, highSide);
      bool fromLow  = DetectSide(-1, rates, rangeHigh, rangeLow, lowSide);

      if(fromHigh && fromLow)
        {
         Print("ORB: setups opuestos en la misma vela, se descarta la señal");
         return false;
        }
      if(!fromHigh && !fromLow)
         return false;

      if(fromHigh)
         signal = highSide;
      else
         signal = lowSide;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| CPositionManager: posición del EA (símbolo + magic), cierre       |
//| parcial por R, break even posterior y cierre forzado.             |
//| El riesgo inicial se lee del historial de la orden de apertura,   |
//| por lo que la gestión sobrevive a reinicios del terminal.         |
//+------------------------------------------------------------------+
class CPositionManager
  {
private:
   CTrade           *m_trade;
   long              m_magic;
   bool              m_usePartial;
   double            m_partialAtR;
   double            m_partialPercent;
   bool              m_breakEven;

   ulong             m_trackedTicket;
   bool              m_trackingValid;
   bool              m_loadWarned;
   double            m_initialVolume;
   double            m_initialRisk;
   bool              m_partialSkipped;

   bool              LoadInitialRisk(ulong ticket)
     {
      long   positionId = PositionGetInteger(POSITION_IDENTIFIER);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);

      if(!HistorySelectByPosition(positionId))
         return false;

      ulong  openingOrder = 0;
      double volume       = 0.0;
      int    deals        = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
         volume += HistoryDealGetDouble(deal, DEAL_VOLUME);
         if(openingOrder == 0)
            openingOrder = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
        }

      double initialSl = (openingOrder > 0) ? HistoryOrderGetDouble(openingOrder, ORDER_SL) : 0.0;
      if(initialSl <= 0.0 || volume <= 0.0)
         return false;

      m_initialVolume = volume;
      m_initialRisk   = MathAbs(openPrice - initialSl);
      return m_initialRisk > 0.0;
     }

   bool              ClosePartialVolume(ulong ticket, double volume)
     {
      if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
         return m_trade.PositionClosePartial(ticket, volume);

      //--- Cuenta netting: CTrade::PositionClosePartial solo admite hedging; se reduce la
      //--- posición con una operación opuesta que reenvía el SL/TP vigente para no perderlos.
      bool   isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      return isBuy ? m_trade.Sell(volume, _Symbol, 0.0, sl, tp) : m_trade.Buy(volume, _Symbol, 0.0, sl, tp);
     }

   void              ManagePartialClose(ulong ticket)
     {
      double step          = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minVolume     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      if(m_partialSkipped || currentVolume < m_initialVolume - step / 2.0)
         return;

      bool   isBuy     = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double price     = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double target    = isBuy ? openPrice + m_partialAtR * m_initialRisk : openPrice - m_partialAtR * m_initialRisk;
      if(isBuy ? price < target : price > target)
         return;

      double closeVolume = MathFloor(currentVolume * m_partialPercent / 100.0 / step + 1e-9) * step;
      if(closeVolume < minVolume || currentVolume - closeVolume < minVolume - step / 2.0)
        {
         Print("ORB: volumen ", currentVolume, " insuficiente para un cierre parcial del ", m_partialPercent, "%, se omite");
         m_partialSkipped = true;
         return;
        }

      if(!ClosePartialVolume(ticket, closeVolume))
        {
         Print(__FUNCTION__, ": fallo en cierre parcial, retcode=", m_trade.ResultRetcode(),
               " desc=", m_trade.ResultRetcodeDescription());
         return;
        }

      Print("ORB: cierre parcial de ", closeVolume, " lotes a ", m_partialAtR, "R");
     }

   void              ManageBreakEven(ulong ticket)
     {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(PositionGetDouble(POSITION_VOLUME) >= m_initialVolume - step / 2.0)
         return;

      bool   isBuy     = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSl = PositionGetDouble(POSITION_SL);
      if(currentSl > 0.0 && (isBuy ? currentSl >= openPrice : currentSl <= openPrice))
         return;

      double minDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      double price       = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(isBuy ? price - openPrice <= minDistance : openPrice - price <= minDistance)
         return;

      if(m_trade.PositionModify(ticket, openPrice, PositionGetDouble(POSITION_TP)))
         Print("ORB: stop movido a break even (", openPrice, ")");
      else
         Print(__FUNCTION__, ": fallo moviendo a break even, retcode=", m_trade.ResultRetcode());
     }

public:
                     CPositionManager(void) : m_trade(NULL), m_magic(0), m_usePartial(false), m_partialAtR(1.0),
                                              m_partialPercent(50.0), m_breakEven(true), m_trackedTicket(0),
                                              m_trackingValid(false), m_loadWarned(false), m_initialVolume(0.0), m_initialRisk(0.0),
                                              m_partialSkipped(false) {}

   void              Init(CTrade *trade, long magic, bool usePartial, double partialAtR, double partialPercent, bool breakEven)
     {
      m_trade          = trade;
      m_magic          = magic;
      m_usePartial     = usePartial;
      m_partialAtR     = partialAtR;
      m_partialPercent = partialPercent;
      m_breakEven      = breakEven;
     }

   //--- Selecciona y devuelve la posición del EA en este símbolo (0 si no hay).
   ulong             FindPosition(void) const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == m_magic)
            return ticket;
        }
      return 0;
     }

   void              Manage(ulong ticket)
     {
      if(!m_usePartial)
         return;

      if(ticket != m_trackedTicket)
        {
         m_trackedTicket  = ticket;
         m_trackingValid  = false;
         m_loadWarned     = false;
         m_partialSkipped = false;
        }

      //--- Recién abierta, la posición puede no figurar aún en el historial: se reintenta.
      if(!m_trackingValid)
        {
         m_trackingValid = LoadInitialRisk(ticket);
         if(!PositionSelectByTicket(ticket))
            return;
         if(!m_trackingValid)
           {
            if(!m_loadWarned)
               Print("ORB: aún sin stop inicial en el historial de la posición ", ticket, ", cierre parcial en espera");
            m_loadWarned = true;
            return;
           }
        }

      ManagePartialClose(ticket);
      if(m_breakEven && PositionSelectByTicket(ticket))
         ManageBreakEven(ticket);
     }

   void              Close(ulong ticket, string reason)
     {
      if(m_trade.PositionClose(ticket))
         Print("ORB: posición cerrada por ", reason);
      else
         Print(__FUNCTION__, ": fallo al cerrar posición por ", reason, ", retcode=", m_trade.ResultRetcode());
     }
  };

//+------------------------------------------------------------------+
//| CExpertAdvisor: orquesta horario, rango, setup, filtros y riesgo  |
//+------------------------------------------------------------------+
class CExpertAdvisor
  {
private:
   CTrade            m_trade;
   CTradingSchedule  m_schedule;
   CBarMonitor       m_barMonitor;
   CSignalFilter     m_filter;
   COrbRange         m_range;
   COrbSetupDetector m_detector;
   CPositionManager  m_positions;

   long              m_magic;
   ENUM_TIMEFRAMES   m_confirmTimeframe;
   ENUM_ORB_SETUP    m_setup;
   int               m_maxTradesPerDay;
   bool              m_useMoneyManagement;
   double            m_riskPercent;
   double            m_fixedLots;
   ENUM_ORB_SL_MODE  m_slMode;
   double            m_slBufferPoints;
   ENUM_ORB_TP_MODE  m_tpMode;
   double            m_riskReward;
   double            m_rangeTpMultiplier;

   static ENUM_TIMEFRAMES ResolveTimeframe(ENUM_TIMEFRAMES timeframe)
     {
      return timeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : timeframe;
     }

   static double     NormalizePrice(double price)
     {
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize > 0.0)
         price = MathRound(price / tickSize) * tickSize;
      return NormalizeDouble(price, _Digits);
     }

   static double     NormalizeVolumeDown(double volume)
     {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0.0)
         return 0.0;

      int digits = (int)MathMax(0.0, MathCeil(-MathLog10(step)));
      return NormalizeDouble(MathFloor(volume / step + 1e-9) * step, digits);
     }

   int               CountTradesToday(void) const
     {
      if(!HistorySelect(m_schedule.DayStart(), TimeCurrent()))
        {
         Print(__FUNCTION__, ": no se pudo leer el historial, se bloquean nuevas entradas");
         return INT_MAX;
        }

      int count = 0;
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(deal, DEAL_MAGIC) == m_magic &&
            HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
            count++;
        }
      return count;
     }

   //--- Velas cerradas de confirmación desde que el rango está listo, más la vela previa.
   bool              CopyWindowRates(MqlRates &rates[])
     {
      datetime from  = m_range.ReadyTime();
      int      shift = iBarShift(_Symbol, m_confirmTimeframe, from, false);
      if(shift < 0)
         return false;
      if(iTime(_Symbol, m_confirmTimeframe, shift) < from)
         shift--;
      if(shift < 1)
         return false;

      int count = shift + 1;
      ArraySetAsSeries(rates, false);
      return CopyRates(_Symbol, m_confirmTimeframe, 1, count, rates) == count;
     }

   double            CalculateLots(int direction, double entryPrice, double slPrice)
     {
      double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

      if(!m_useMoneyManagement)
         return MathMax(minVolume, MathMin(maxVolume, NormalizeVolumeDown(m_fixedLots)));

      double lossPerLot = 0.0;
      ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, slPrice, lossPerLot) || lossPerLot >= 0.0)
        {
         Print(__FUNCTION__, ": no se pudo calcular la pérdida por lote, code=", GetLastError());
         return 0.0;
        }

      double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (m_riskPercent / 100.0);
      double lots       = NormalizeVolumeDown(riskAmount / -lossPerLot);

      //--- Subir al lote mínimo arriesgaría más que el % configurado: se descarta.
      if(lots < minVolume)
        {
         Print("ORB: el lote para ", m_riskPercent, "% de riesgo (", lots, ") es menor al mínimo (",
               minVolume, "), se descarta la entrada");
         return 0.0;
        }

      return MathMin(maxVolume, lots);
     }

   double            ResolveStopLevel(const SOrbSignal &signal) const
     {
      if(m_slMode == ORB_SL_MIDPOINT && m_setup != ORB_SETUP_LIQUIDITY_SWEEP)
         return m_range.Mid();
      return signal.stopLevel;
     }

   double            ResolveTakeProfit(int direction, double entryPrice, double risk) const
     {
      switch(m_tpMode)
        {
         case ORB_TP_RISK_REWARD:
            return NormalizePrice(entryPrice + direction * risk * m_riskReward);
         case ORB_TP_RANGE_MULTIPLE:
            return NormalizePrice(entryPrice + direction * m_range.Height() * m_rangeTpMultiplier);
         default:
            return 0.0;
        }
     }

   bool              OpenPosition(const SOrbSignal &signal)
     {
      int    direction   = signal.direction;
      double entryPrice  = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double buffer      = m_slBufferPoints * _Point;
      double sl          = NormalizePrice(ResolveStopLevel(signal) - direction * buffer);
      double risk        = direction * (entryPrice - sl);
      double minDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

      if(risk <= minDistance)
        {
         Print("ORB: stop ", sl, " inválido para entrada ", entryPrice, " (distancia mínima ", minDistance, "), se descarta");
         return false;
        }

      double tp = ResolveTakeProfit(direction, entryPrice, risk);
      if(tp != 0.0 && direction * (tp - entryPrice) <= minDistance)
        {
         Print("ORB: take profit ", tp, " demasiado cercano a la entrada ", entryPrice, ", se descarta");
         return false;
        }

      double lots = CalculateLots(direction, entryPrice, sl);
      if(lots <= 0.0)
         return false;

      string comment = "ORB-" + StringSubstr(EnumToString(m_setup), 10);
      bool   result  = (direction == 1)
                       ? m_trade.Buy(lots, _Symbol, entryPrice, sl, tp, comment)
                       : m_trade.Sell(lots, _Symbol, entryPrice, sl, tp, comment);

      if(!result)
         Print(__FUNCTION__, ": fallo al enviar orden, retcode=", m_trade.ResultRetcode(),
               " desc=", m_trade.ResultRetcodeDescription());

      return result;
     }

   void              TryEnter(void)
     {
      if(!m_range.IsReady() || m_schedule.IsPastSessionClose())
         return;

      datetime signalBarOpen  = iTime(_Symbol, m_confirmTimeframe, 1);
      datetime signalBarClose = signalBarOpen + PeriodSeconds(m_confirmTimeframe);
      if(signalBarOpen == 0 || signalBarOpen < m_range.ReadyTime() || signalBarClose > m_schedule.TradeEnd())
         return;

      MqlRates rates[];
      if(!CopyWindowRates(rates))
         return;

      SOrbSignal signal;
      ZeroMemory(signal);
      if(!m_detector.Evaluate(rates, m_range.High(), m_range.Low(), signal))
         return;

      if(CountTradesToday() >= m_maxTradesPerDay)
         return;

      if(!m_filter.IsAllowedToTrade(signal.direction))
        {
         Print("ORB: señal ", (signal.direction == 1 ? "compra" : "venta"), " bloqueada por filtros de volumen/RSI");
         return;
        }

      OpenPosition(signal);
     }

public:
                     CExpertAdvisor(void) : m_magic(0), m_confirmTimeframe(PERIOD_CURRENT), m_setup(ORB_SETUP_BREAKOUT),
                                            m_maxTradesPerDay(1), m_useMoneyManagement(true), m_riskPercent(1.0),
                                            m_fixedLots(0.1), m_slMode(ORB_SL_STRUCTURE), m_slBufferPoints(0.0),
                                            m_tpMode(ORB_TP_RISK_REWARD), m_riskReward(2.0), m_rangeTpMultiplier(1.0) {}

   bool              Init(void)
     {
      ENUM_TIMEFRAMES rangeTimeframe = ResolveTimeframe(InpRangeTimeframe);
      m_confirmTimeframe             = ResolveTimeframe(InpConfirmTimeframe);

      if(PeriodSeconds(m_confirmTimeframe) > PeriodSeconds(rangeTimeframe))
        {
         Print("ORB: la temporalidad de confirmación debe ser menor o igual a la del rango");
         return false;
        }
      if(InpMaxTradesPerDay < 1 || InpSweepMaxBars < 0 || InpFvgMaxBars < 0 || InpSlBufferPoints < 0)
        {
         Print("ORB: máx. operaciones/día >= 1; límites de velas y margen de stop >= 0");
         return false;
        }
      if(InpUseMoneyManagement ? InpRiskPercent <= 0.0 : InpFixedLots <= 0.0)
        {
         Print("ORB: el % de riesgo o el lotaje fijo debe ser > 0");
         return false;
        }
      if((InpTpMode == ORB_TP_RISK_REWARD && InpRiskReward <= 0.0) ||
         (InpTpMode == ORB_TP_RANGE_MULTIPLE && InpRangeTpMultiplier <= 0.0))
        {
         Print("ORB: el ratio RR / múltiplo del rango debe ser > 0");
         return false;
        }
      if(InpUsePartialClose && (InpPartialAtR <= 0.0 || InpPartialPercent <= 0.0 || InpPartialPercent >= 100.0))
        {
         Print("ORB: cierre parcial requiere R > 0 y porcentaje entre 0 y 100 (exclusivo)");
         return false;
        }

      m_magic              = InpMagicNumber;
      m_setup              = InpSetup;
      m_maxTradesPerDay    = InpMaxTradesPerDay;
      m_useMoneyManagement = InpUseMoneyManagement;
      m_riskPercent        = InpRiskPercent;
      m_fixedLots          = InpFixedLots;
      m_slMode             = InpSlMode;
      m_slBufferPoints     = InpSlBufferPoints;
      m_tpMode             = InpTpMode;
      m_riskReward         = InpRiskReward;
      m_rangeTpMultiplier  = InpRangeTpMultiplier;

      m_trade.SetExpertMagicNumber(InpMagicNumber);
      m_trade.SetDeviationInPoints(InpSlippage);
      m_trade.SetTypeFillingBySymbol(_Symbol);

      if(!m_schedule.Init(InpTimeReference, InpServerGmtOffset, InpServerDst,
                          InpTradeStartHour, InpTradeStartMinute, InpTradeEndHour, InpTradeEndMinute,
                          InpForceSessionClose, InpSessionCloseHour, InpSessionCloseMinute))
         return false;

      m_barMonitor.Init(m_confirmTimeframe);
      m_range.Init(rangeTimeframe, InpRangeCandle, InpMinRangePoints);
      m_detector.Init(InpSetup, InpSweepMaxBars, InpFvgMaxBars);
      m_positions.Init(GetPointer(m_trade), InpMagicNumber, InpUsePartialClose,
                       InpPartialAtR, InpPartialPercent, InpBreakEvenAfterPartial);

      return m_filter.Init(m_confirmTimeframe, InpUseVolumeFilter, InpVolumePeriod,
                           InpUseRsiFilter, InpRsiPeriod, InpRsiOverbought, InpRsiOversold);
     }

   void              Deinit(void)
     {
      m_filter.Deinit();
     }

   void              OnTick(void)
     {
      if(m_schedule.Refresh())
         m_range.Reset(m_schedule.TradeStart());

      //--- Gestión de la posición abierta: en cada tick (no es una señal de entrada).
      ulong ticket = m_positions.FindPosition();
      if(ticket > 0)
        {
         if(m_schedule.IsPastSessionClose())
           {
            m_positions.Close(ticket, "fin de sesión (sin overnight)");
            return;
           }
         m_positions.Manage(ticket);
        }

      //--- Las entradas se evalúan una vez por vela cerrada de confirmación.
      if(!m_barMonitor.IsNewBar())
         return;

      m_range.Update();

      if(ticket == 0)
         TryEnter();
     }
  };

CExpertAdvisor g_ea;

//+------------------------------------------------------------------+
int OnInit(void)
  {
   if(!g_ea.Init())
     {
      Print("Error inicializando el EA ORB");
      return(INIT_PARAMETERS_INCORRECT);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_ea.Deinit();
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   g_ea.OnTick();
  }
//+------------------------------------------------------------------+
