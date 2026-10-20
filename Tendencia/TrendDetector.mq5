//+------------------------------------------------------------------+
//|                                                TrendDetector.mq5 |
//|  Tendencia principal (alcista / bajista / lateral) según la      |
//|  secuencia de picos y valles en D1 o superior (CTrendDetector).  |
//|                                                                  |
//|  Buffer 0 "Trend": 1 alcista, 0 lateral, -1 bajista. Lectura     |
//|  desde un EA:                                                    |
//|    h = iCustom(_Symbol, _Period, "Tendencia\\TrendDetector");    |
//|    CopyBuffer(h, 0, 0, 1, buf);                                  |
//+------------------------------------------------------------------+
#property copyright "Tendencia"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1
#property indicator_type1   DRAW_NONE
#property indicator_label1  "Trend"

#include "Include\CTrendDetector.mqh"

input group "General"
input string          InpSymbol         = "";        // Símbolo (vacío = símbolo del gráfico)
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_D1; // Timeframe de análisis (D1 o superior)
input int             InpLookbackBars   = 500;       // Velas cerradas analizadas

input group "ZigZag ATR"
input int    InpAtrPeriod     = 14;   // Periodo ATR
input double InpAtrMultiplier = 3.0;  // Reversión mínima para confirmar un swing (x ATR)

input group "Clasificación"
input double InpEqualTolerance = 0.5; // Tolerancia de pico/valle horizontal (x ATR)
input int    InpComparisons    = 1;   // Comparaciones consecutivas exigidas (picos y valles)

input group "Visual"
input bool  InpShowLabel     = true;           // Mostrar etiqueta de tendencia
input bool  InpDrawSwings    = true;           // Dibujar swings (solo si el símbolo es el del gráfico)
input color InpBullColor     = clrLimeGreen;   // Color alcista
input color InpBearColor     = clrTomato;      // Color bajista
input color InpSideColor     = clrDarkGray;    // Color lateral
input color InpSwingColor    = clrDodgerBlue;  // Color de las líneas del ZigZag
input bool  InpAlertOnChange = false;          // Alerta al cambiar la tendencia

double            TrendBuffer[];
CTrendDetector    g_detector;
string            g_prefix;
datetime          g_lastBarTime = 0;
bool              g_hasResult   = false;
ENUM_MARKET_TREND g_lastTrend   = TREND_SIDEWAYS;

color TrendColor(ENUM_MARKET_TREND trend)
  {
   if(trend == TREND_BULLISH)
      return InpBullColor;
   if(trend == TREND_BEARISH)
      return InpBearColor;
   return InpSideColor;
  }

color PivotColor(const STrendPivot &pivot)
  {
   if(pivot.relation == PIVOT_HIGHER)
      return InpBullColor;
   if(pivot.relation == PIVOT_LOWER)
      return InpBearColor;
   return InpSideColor;
  }

void DrawLabel(void)
  {
   string name = g_prefix + "Label";
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 25);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }

   ENUM_MARKET_TREND trend = g_detector.Trend();
   ObjectSetString(0, name, OBJPROP_TEXT,
                   "Tendencia " + g_detector.TimeframeName() + " " + g_detector.AnalyzedSymbol() + ": " +
                   CTrendDetector::TrendToString(trend) + " (" + g_detector.Reason() + ")");
   ObjectSetInteger(0, name, OBJPROP_COLOR, TrendColor(trend));
  }

void DrawSwings(void)
  {
   string swingPrefix = g_prefix + "Swing";
   ObjectsDeleteAll(0, swingPrefix);

   for(int i = 0; i < g_detector.PivotCount(); i++)
     {
      STrendPivot pivot = g_detector.Pivot(i);

      string textName = swingPrefix + "Text" + IntegerToString(i);
      ObjectCreate(0, textName, OBJ_TEXT, 0, pivot.time, pivot.price);
      ObjectSetString(0, textName, OBJPROP_TEXT, CTrendDetector::PivotLabel(pivot));
      ObjectSetInteger(0, textName, OBJPROP_ANCHOR, pivot.isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
      ObjectSetInteger(0, textName, OBJPROP_COLOR, PivotColor(pivot));
      ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, textName, OBJPROP_HIDDEN, true);

      if(i == 0)
         continue;

      STrendPivot previous = g_detector.Pivot(i - 1);
      string lineName = swingPrefix + "Line" + IntegerToString(i);
      ObjectCreate(0, lineName, OBJ_TREND, 0, previous.time, previous.price, pivot.time, pivot.price);
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, InpSwingColor);
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);
     }
  }

void Render(void)
  {
   if(InpShowLabel)
      DrawLabel();
   if(InpDrawSwings && g_detector.AnalyzedSymbol() == _Symbol)
      DrawSwings();
   ChartRedraw();
  }

int OnInit(void)
  {
   string symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!g_detector.Init(symbol, InpTimeframe, InpLookbackBars, InpAtrPeriod,
                       InpAtrMultiplier, InpEqualTolerance, InpComparisons))
      return INIT_PARAMETERS_INCORRECT;

   SetIndexBuffer(0, TrendBuffer, INDICATOR_DATA);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   string shortName = "TrendDetector(" + symbol + "," + g_detector.TimeframeName() + "," +
                      DoubleToString(InpAtrMultiplier, 1) + ")";
   IndicatorSetString(INDICATOR_SHORTNAME, shortName);
   g_prefix = shortName + "_";

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(prev_calculated == 0)
      ArrayInitialize(TrendBuffer, EMPTY_VALUE);

   //--- Solo se recalcula al abrir una vela nueva del timeframe de análisis (o si aún no hay resultado)
   datetime barTime = iTime(g_detector.AnalyzedSymbol(), g_detector.AnalyzedTimeframe(), 0);
   if(barTime == 0)
      return prev_calculated;

   if(!g_hasResult || barTime != g_lastBarTime)
     {
      if(!g_detector.Update())
         return prev_calculated;

      ENUM_MARKET_TREND trend = g_detector.Trend();
      if(InpAlertOnChange && g_hasResult && trend != g_lastTrend)
         Alert("TrendDetector ", g_detector.AnalyzedSymbol(), " ", g_detector.TimeframeName(), ": ",
               CTrendDetector::TrendToString(g_lastTrend), " -> ", CTrendDetector::TrendToString(trend));

      g_lastTrend   = trend;
      g_lastBarTime = barTime;
      g_hasResult   = true;
      Render();
     }

   TrendBuffer[rates_total - 1] = (double)g_detector.Trend();
   return rates_total;
  }
//+------------------------------------------------------------------+
