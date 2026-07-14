//+------------------------------------------------------------------+
//|                                               ProfitScalper.mq5  |
//|  Открывает Buy/Sell, закрывает сразу при фиксированной прибыли,  |
//|  повторяет цикл до остановки советника.                          |
//+------------------------------------------------------------------+
#property copyright "ProfitScalper"
#property version   "1.00"
#property description "Скальпер: вход в сделку и мгновенное закрытие при прибыли"

#include <Trade/Trade.mqh>

enum ENUM_TRADE_DIRECTION
  {
   DIR_BUY  = 0,  // Только Buy
   DIR_SELL = 1,  // Только Sell
   DIR_AUTO = 2   // Авто: по направлению последнего тика
  };

enum ENUM_PROFIT_MODE
  {
   PROFIT_MONEY  = 0, // Прибыль в деньгах депозита
   PROFIT_POINTS = 1  // Прибыль в пунктах
  };

input group "=== Торговля ==="
input ENUM_TRADE_DIRECTION InpDirection   = DIR_AUTO;   // Направление
input double               InpLot         = 0.01;       // Лот
input ENUM_PROFIT_MODE     InpProfitMode  = PROFIT_MONEY; // Режим фиксации прибыли
input double               InpMinProfit   = 0.10;       // Мин. прибыль для закрытия ($ или пункты)
input int                  InpMagic       = 26071401;   // Magic number
input int                  InpDeviation   = 30;         // Допустимое проскальзывание (пункты)
input int                  InpPauseMs     = 200;        // Пауза между закрытием и новым входом (мс)

input group "=== Защита ==="
input bool                 InpUseStopLoss = false;      // Использовать Stop Loss
input int                  InpStopLossPts = 100;        // Stop Loss (пункты)
input bool                 InpMaxLossDay  = false;      // Лимит убытка за день
input double               InpMaxLossMoney = 50.0;      // Макс. убыток за день ($)

CTrade         trade;
datetime       g_day_start      = 0;
double         g_day_pnl        = 0.0;
bool           g_trading_paused = false;
double         g_last_bid       = 0.0;
double         g_last_ask       = 0.0;
ulong          g_last_close_ms  = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_day_start = DayStart();
   g_day_pnl   = 0.0;
   g_last_bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_last_ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   PrintFormat("ProfitScalper запущен | %s | lot=%.2f | minProfit=%.2f (%s)",
               _Symbol, InpLot, InpMinProfit,
               InpProfitMode == PROFIT_MONEY ? "money" : "points");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("ProfitScalper остановлен");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDayIfNeeded();

   if(g_trading_paused)
      return;

   if(InpMaxLossDay && g_day_pnl <= -MathAbs(InpMaxLossMoney))
     {
      if(!g_trading_paused)
        {
         PrintFormat("Достигнут лимит дневного убытка: %.2f. Торговля остановлена.", g_day_pnl);
         g_trading_paused = true;
        }
      return;
     }

   if(HasOurPosition())
     {
      TryCloseOnProfit();
      return;
     }

   // Пауза после закрытия, чтобы не спамить ордерами
   if(g_last_close_ms > 0 && (GetTickCount64() - g_last_close_ms) < (ulong)InpPauseMs)
      return;

   OpenNewTrade();
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // Учитываем закрытые нами сделки в дневной P&L
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   long magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(magic != InpMagic)
      return;

   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(symbol != _Symbol)
      return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
      return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   g_day_pnl += profit;
  }

//+------------------------------------------------------------------+
datetime DayStart()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
void ResetDayIfNeeded()
  {
   datetime start = DayStart();
   if(start != g_day_start)
     {
      g_day_start      = start;
      g_day_pnl        = 0.0;
      g_trading_paused = false;
      Print("Новый торговый день — счётчик P&L обнулён");
     }
  }

//+------------------------------------------------------------------+
bool HasOurPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool SelectOurPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
     }
   ticket = 0;
   return false;
  }

//+------------------------------------------------------------------+
double PositionProfitMoney()
  {
   // Floating P&L позиции (комиссия учитывается при закрытии в сделке)
   return PositionGetDouble(POSITION_PROFIT)
        + PositionGetDouble(POSITION_SWAP);
  }

//+------------------------------------------------------------------+
double PositionProfitPoints()
  {
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   long   type       = PositionGetInteger(POSITION_TYPE);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   if(type == POSITION_TYPE_BUY)
      return (bid - open_price) / point;
   return (open_price - ask) / point;
  }

//+------------------------------------------------------------------+
bool IsProfitReady()
  {
   if(InpProfitMode == PROFIT_MONEY)
      return PositionProfitMoney() >= InpMinProfit;
   return PositionProfitPoints() >= InpMinProfit;
  }

//+------------------------------------------------------------------+
void TryCloseOnProfit()
  {
   ulong ticket;
   if(!SelectOurPosition(ticket))
      return;

   if(!IsProfitReady())
      return;

   double profit = PositionProfitMoney();
   double points = PositionProfitPoints();

   if(trade.PositionClose(ticket, InpDeviation))
     {
      g_last_close_ms = GetTickCount64();
      PrintFormat("Закрыто #%I64u | profit=%.2f | points=%.1f", ticket, profit, points);
     }
   else
     {
      PrintFormat("Ошибка закрытия #%I64u: %d %s",
                  ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE ResolveDirection()
  {
   if(InpDirection == DIR_BUY)
      return ORDER_TYPE_BUY;
   if(InpDirection == DIR_SELL)
      return ORDER_TYPE_SELL;

   // AUTO: направление последнего движения котировки
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   ENUM_ORDER_TYPE dir = ORDER_TYPE_BUY;
   if(bid > g_last_bid)
      dir = ORDER_TYPE_BUY;
   else if(bid < g_last_bid)
      dir = ORDER_TYPE_SELL;
   else if(ask > g_last_ask)
      dir = ORDER_TYPE_BUY;
   else if(ask < g_last_ask)
      dir = ORDER_TYPE_SELL;

   g_last_bid = bid;
   g_last_ask = ask;
   return dir;
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step_lot <= 0.0)
      step_lot = 0.01;

   lot = MathFloor(lot / step_lot + 1e-12) * step_lot;
   if(lot < min_lot)
      lot = min_lot;
   if(lot > max_lot)
      lot = max_lot;
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
void OpenNewTrade()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return;

   ENUM_ORDER_TYPE type = ResolveDirection();
   double lot = NormalizeLot(InpLot);

   double sl = 0.0;
   if(InpUseStopLoss && InpStopLossPts > 0)
     {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      if(type == ORDER_TYPE_BUY)
         sl = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - InpStopLossPts * point, digits);
      else
         sl = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + InpStopLossPts * point, digits);
     }

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(lot, _Symbol, 0.0, sl, 0.0, "ProfitScalper Buy");
   else
      ok = trade.Sell(lot, _Symbol, 0.0, sl, 0.0, "ProfitScalper Sell");

   if(ok)
      PrintFormat("Открыто %s | lot=%.2f | ticket=%I64u",
                  type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                  lot, trade.ResultOrder());
   else
      PrintFormat("Ошибка открытия: %d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
