//+------------------------------------------------------------------+
//|                                                CTradeManager.mqh |
//|  Ejecución vía CTrade: apertura (mercado o pendiente al quiebre),|
//|  cierre parcial en TP1 (extensión 127.2%) y trailing stop hacia   |
//|  TP2 (extensión 161.8%) sobre el remanente.                       |
//+------------------------------------------------------------------+
#ifndef FIBEA_TRADE_MANAGER_MQH
#define FIBEA_TRADE_MANAGER_MQH

#include <Trade\Trade.mqh>

class CTradeManager
  {
private:
   CTrade            m_trade;
   int               m_magic;
   double            m_tp1Price;
   double            m_tp2Price;
   double            m_partialClosePercent;
   bool              m_useTrailingAfterPartial;
   double            m_trailingPoints;
   bool              m_tp1Evaluated;   // ya se evaluó si tocó TP1 (evita reintentar cada tick)
   bool              m_partialFilled;  // el cierre parcial en TP1 se ejecutó realmente

   bool              HasOpenPosition(void) const
     {
      return PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == m_magic;
     }

   double            NormalizeCloseVolume(double totalVolume) const
     {
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      double closeVolume = totalVolume * (m_partialClosePercent / 100.0);
      closeVolume = MathFloor(closeVolume / lotStep) * lotStep;

      double remaining = totalVolume - closeVolume;
      if(closeVolume < lotMin || remaining < lotMin)
         return 0.0; // no alcanza para dividir; se deja la posición completa a TP1

      return closeVolume;
     }

   void              TrailStop(bool isLong, double bid, double ask, double currentSl)
     {
      double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double distance = m_trailingPoints * point;
      double newSl    = isLong ? (bid - distance) : (ask + distance);

      bool improves = isLong ? (newSl > currentSl) : (currentSl == 0.0 || newSl < currentSl);
      if(!improves)
         return;

      if(!m_trade.PositionModify(_Symbol, newSl, m_tp2Price))
         Print(__FUNCTION__, ": fallo al mover trailing stop, retcode=", m_trade.ResultRetcode());
     }

public:
                     CTradeManager(void) : m_magic(0), m_tp1Price(0.0), m_tp2Price(0.0),
                                            m_partialClosePercent(50.0), m_useTrailingAfterPartial(true),
                                            m_trailingPoints(300.0), m_tp1Evaluated(false), m_partialFilled(false) {}

   void              Init(int magic, int slippage, double partialClosePercent,
                           bool useTrailingAfterPartial, double trailingPoints)
     {
      m_magic                   = magic;
      m_partialClosePercent     = partialClosePercent;
      m_useTrailingAfterPartial = useTrailingAfterPartial;
      m_trailingPoints          = trailingPoints;

      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(slippage);
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);
     }

   bool              OpenMarketPosition(int direction, double lots, double sl, double tp1, double tp2)
     {
      m_tp1Price      = tp1;
      m_tp2Price      = tp2;
      m_tp1Evaluated  = false;
      m_partialFilled = false;

      double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      bool result = (direction == 1)
                    ? m_trade.Buy(lots, _Symbol, price, sl, tp1)
                    : m_trade.Sell(lots, _Symbol, price, sl, tp1);

      if(!result)
         Print(__FUNCTION__, ": fallo al abrir posicion, retcode=", m_trade.ResultRetcode(),
               " desc=", m_trade.ResultRetcodeDescription());

      return result;
     }

   //--- Entrada en el quiebre del máximo/mínimo de la vela de confirmación (orden pendiente)
   bool              OpenStopOrder(int direction, double lots, double triggerPrice, double sl, double tp1, double tp2)
     {
      m_tp1Price      = tp1;
      m_tp2Price      = tp2;
      m_tp1Evaluated  = false;
      m_partialFilled = false;

      bool result = (direction == 1)
                    ? m_trade.BuyStop(lots, triggerPrice, _Symbol, sl, tp1, ORDER_TIME_GTC, 0)
                    : m_trade.SellStop(lots, triggerPrice, _Symbol, sl, tp1, ORDER_TIME_GTC, 0);

      if(!result)
         Print(__FUNCTION__, ": fallo al colocar orden pendiente, retcode=", m_trade.ResultRetcode(),
               " desc=", m_trade.ResultRetcodeDescription());

      return result;
     }

   //--- Cancela órdenes pendientes propias no llenadas (la señal es válida solo 1 vela)
   void              CancelPendingOrders(void)
     {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) != m_magic) continue;

         if(!m_trade.OrderDelete(ticket))
            Print(__FUNCTION__, ": fallo al cancelar pendiente ", ticket, ", retcode=", m_trade.ResultRetcode());
        }
     }

   bool              HasPendingOrder(void) const
     {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == m_magic)
            return true;
        }
      return false;
     }

   //--- Gestión de la posición abierta: cierre parcial en TP1 + trailing hacia TP2.
   //--- Se evalúa en cada tick (gestión de salida, no señal de entrada).
   void              ManageOpenPosition(void)
     {
      if(!HasOpenPosition())
        {
         m_tp1Evaluated  = false;
         m_partialFilled = false;
         return;
        }

      long   type      = PositionGetInteger(POSITION_TYPE);
      double volume     = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSl = PositionGetDouble(POSITION_SL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      bool isLong = (type == POSITION_TYPE_BUY);

      if(!m_tp1Evaluated)
        {
         bool reachedTp1 = isLong ? (bid >= m_tp1Price) : (ask <= m_tp1Price);
         if(reachedTp1)
           {
            m_tp1Evaluated = true;

            double closeVolume = NormalizeCloseVolume(volume);
            if(closeVolume > 0.0)
              {
               if(m_trade.PositionClosePartial(_Symbol, closeVolume))
                 {
                  m_partialFilled = true;
                  // Breakeven en el remanente y TP hacia el segundo objetivo (161.8%)
                  if(!m_trade.PositionModify(_Symbol, openPrice, m_tp2Price))
                     Print(__FUNCTION__, ": fallo al mover SL a breakeven, retcode=", m_trade.ResultRetcode());
                 }
               else
                 {
                  m_partialFilled = false; // no se logró dividir; se deja el TP1 original intacto
                  Print(__FUNCTION__, ": fallo en cierre parcial, retcode=", m_trade.ResultRetcode());
                 }
              }
            // closeVolume == 0.0: volumen insuficiente para dividir; sigue completa hacia TP1,
            // sin activar trailing/TP2 (m_partialFilled permanece false).
           }
        }

      if(m_partialFilled && m_useTrailingAfterPartial)
         TrailStop(isLong, bid, ask, currentSl);
     }
  };

#endif // FIBEA_TRADE_MANAGER_MQH
