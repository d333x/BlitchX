//+------------------------------------------------------------------+
//|                                               ProfitScalper.mq5  |
//|  v3.97 — предикт по микро-потоку (M1–M15), H1 только фильтр       |
//|  Конфликт H1≠LTF → не BUY «в лоб», ждём или SELL по факту         |
#property copyright "ProfitScalper"
#property version   "3.97"
#property description "Прогноз ближайшего хода. BUY и SELL равноправны. Конфликт ТФ = ждать."

#include <Trade/Trade.mqh>
#include "../Include/ChartKnowledge.mqh"

enum ENUM_TRADE_DIRECTION
  {
   DIR_BUY  = 0,
   DIR_SELL = 1,
   DIR_AUTO = 2
  };

input group "=== Торговля ==="
input ENUM_TRADE_DIRECTION InpDirection = DIR_AUTO;
input double               InpLot       = 0.05;
input int                  InpMagic     = 26071470;
input int                  InpDeviation = 30;
input int                  InpMaxPositions = 1;
input int                  InpBasketOpen = 1;
input int                  InpMaxTradesDay = 120;
input bool                 InpFarmLoop = true;
input int                  InpFarmCooldownMs = 8000;   // после успешного входа
input int                  InpLossCooldownMs = 45000;  // после минуса — короткий cooldown
input bool                 InpRefillBasket = false;

input group "=== Символ ==="
input bool                 InpTradeOnlyChart = true;
input string               InpAlsoSymbols = "";

input group "=== Предикт прибыли (СУММА $) ==="
input bool                 InpUseKnowledge = true;
input bool                 InpSmartBigProfit = true;
input bool                 InpOnlyBigOpportunity = true; // НЕ торгуем МЕЛКИЙ/СРЕДНИЙ
input double               InpMinEnterConf = 72.0;       // порог уверенности для BIG
input double               InpMinProfitMoney = 8.00;    // цель лока (не крошки $1–2)
input double               InpBigProfitMoney = 12.00;   // сильный BIG — держим дольше
input double               InpArmLockMoney = 6.00;      // peak-lock только после реального плюса
input double               InpStrongScoreGap = 8.0;
input double               InpStrongRR = 2.5;           // TP дальше cut — expectancy > 0
input double               InpWeakRR = 1.5;
input bool                 InpCloseOnProfit  = true;
input bool                 InpCloseEachAlone = true;
input int                  InpLockTimerMs    = 100;
input bool                 InpUseBreakEven = true;
input double               InpBE_R = 0.5;
input double               InpBE_OffsetPts = 2.0;
input bool                 InpUseTrailing = true;
input double               InpTrailStart_R = 0.6;
input double               InpTrailATR_Mult = 0.6;
input bool                 InpSendStopsAtOpen = false; // false = рынок без SL/TP (лок/кат сам EA)

input group "=== Анализ ==="
input ENUM_TIMEFRAMES      InpTrendTF   = PERIOD_H1;
input ENUM_TIMEFRAMES      InpSignalTF  = PERIOD_M15;
input int                  InpFastEMA   = 20;
input int                  InpSlowEMA   = 50;
input int                  InpATRPeriod = 14;
input double               InpATR_SL_Mult = 1.2;       // SL ближе к риску cut (R:R)
input bool                 InpUseSpreadFilter = true;
input int                  InpMaxSpreadPts = 400;

input group "=== База знаний ==="
input bool                 InpStickyLastDir = false;
input int                  InpKnowledgeGap = 0;
input bool                 InpRequireClearFlow = true;
input bool                 InpCloseAgainstFlow = false;
input double               InpBasketCutLoss = 4.00;    // 1 cut < 1 lock ($8)
input int                  InpCutGraceSec = 45;
input double               InpPanicCutMoney = 5.00;    // было $12 = 6 локов по $2; теперь ≤ 1 лока

input group "=== Защита ==="
input bool                 InpMaxLossDay = true;
input double               InpMaxLossMoney = 40.0;
input bool                 InpMaxLossPct = false;
input double               InpMaxLossPercent = 5.0;
input bool                 InpPauseIfExpenseLeads = true;
input double               InpExpenseLeadBuffer = 20.0; // пауза только если net уже ≤ −buffer

#define MAX_SYMS 8

CTrade trade;

string g_syms[MAX_SYMS];
int    g_sym_count = 0;
int    g_ema_fast[MAX_SYMS];
int    g_ema_slow[MAX_SYMS];
int    g_atr[MAX_SYMS];
ulong  g_last_farm_ms[MAX_SYMS];
ulong  g_last_skip_ms[MAX_SYMS];
ulong  g_pause_until_ms[MAX_SYMS];
ENUM_ORDER_TYPE g_last_dir[MAX_SYMS];
bool   g_have_dir[MAX_SYMS];
double g_pred_gap[MAX_SYMS];
bool   g_pred_strong[MAX_SYMS];
double g_lock_target[MAX_SYMS];
double g_peak_money[MAX_SYMS];
string g_pred_side[MAX_SYMS];
double g_score_buy[MAX_SYMS];
double g_score_sell[MAX_SYMS];
string g_score_why[MAX_SYMS];
string g_wait_why[MAX_SYMS];
string g_signal_txt[MAX_SYMS];
string g_analysis[MAX_SYMS];
double g_conf[MAX_SYMS];
bool   g_signal_enter[MAX_SYMS];
double g_expected_usd[MAX_SYMS];
int    g_opp_size[MAX_SYMS];       // OPP_SMALL/MID/BIG
int    g_align_score[MAX_SYMS];
string g_block_reason[MAX_SYMS];   // почему нет ордера при сигнале
ulong  g_last_pulse_ms = 0;
ulong  g_last_signal_print_ms = 0;
ulong  g_last_block_print_ms = 0;

datetime g_day_start = 0;
double   g_day_pnl = 0.0;
double   g_day_income = 0.0;   // сумма плюсовых закрытий ($)
double   g_day_expense = 0.0;  // сумма минусовых закрытий ($) — расход
double   g_day_start_balance = 0.0;
bool     g_trading_paused = false;
int      g_trades_today = 0;
int      g_loss_streak = 0;

struct MarketScore
  {
   double atr_pts;
   double spread_pts;
   bool   trend_up;
   bool   trend_down;
  };

//+------------------------------------------------------------------+
string TrimStr(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
bool IsGoldSymbol(const string sym)
  {
   string u = sym;
   StringToUpper(u);
   return (StringFind(u, "XAU") >= 0 || StringFind(u, "GOLD") >= 0);
  }

//+------------------------------------------------------------------+
double LotForSymbol(const string sym)
  {
   return InpLot;
  }

//+------------------------------------------------------------------+
double MinProfitForSymbol(const string sym)
  {
   for(int i = 0; i < g_sym_count; i++)
     {
      if(g_syms[i] == sym)
         return MathMax(g_lock_target[i], InpMinProfitMoney);
     }
   return InpMinProfitMoney;
  }

//+------------------------------------------------------------------+
string ResolveGoldName()
  {
   string cands[] = {"XAUUSD", "XAUUSDm", "XAUUSD.", "GOLD", "GOLDm", "XAUUSD.a"};
   for(int i = 0; i < ArraySize(cands); i++)
     {
      if(SymbolSelect(cands[i], true))
         return cands[i];
     }
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      string u = name;
      StringToUpper(u);
      if(StringFind(u, "XAUUSD") >= 0 || u == "GOLD")
        {
         SymbolSelect(name, true);
         return name;
        }
     }
   return "";
  }

//+------------------------------------------------------------------+
void AddSymbolUnique(const string sym)
  {
   if(sym == "" || g_sym_count >= MAX_SYMS)
      return;
   for(int i = 0; i < g_sym_count; i++)
      if(g_syms[i] == sym)
         return;
   if(!SymbolSelect(sym, true))
     {
      PrintFormat("Символ недоступен: %s", sym);
      return;
     }
   g_syms[g_sym_count++] = sym;
  }

//+------------------------------------------------------------------+
void BuildSymbolList()
  {
   g_sym_count = 0;
   // По умолчанию — ТОЛЬКО символ графика, куда накинули EA
   if(InpTradeOnlyChart || InpAlsoSymbols == "")
     {
      AddSymbolUnique(_Symbol);
      return;
     }

   AddSymbolUnique(_Symbol);
   string raw = InpAlsoSymbols;
   string parts[];
   int n = StringSplit(raw, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string s = TrimStr(parts[i]);
      if(s == "")
         continue;
      string u = s;
      StringToUpper(u);
      if(u == "XAUUSD" || u == "GOLD" || u == "XAU")
        {
         string g = ResolveGoldName();
         if(g != "")
            AddSymbolUnique(g);
         continue;
        }
      AddSymbolUnique(s);
     }

   if(g_sym_count == 0)
      AddSymbolUnique(_Symbol);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetAsyncMode(false);

   BuildSymbolList();
   if(g_sym_count < 1)
     {
      Print("Нет символов для торговли");
      return INIT_FAILED;
     }

   for(int i = 0; i < g_sym_count; i++)
     {
      g_ema_fast[i] = iMA(g_syms[i], InpTrendTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_ema_slow[i] = iMA(g_syms[i], InpTrendTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_atr[i]      = iATR(g_syms[i], InpSignalTF, InpATRPeriod);
      g_last_farm_ms[i] = 0;
      g_last_skip_ms[i] = 0;
      g_pause_until_ms[i] = 0;
      g_last_dir[i] = ORDER_TYPE_BUY;
      g_have_dir[i] = false;
      g_pred_gap[i] = 0;
      g_pred_strong[i] = false;
      g_lock_target[i] = InpMinProfitMoney;
      g_peak_money[i] = 0.0;
      g_pred_side[i] = "?";
      g_score_buy[i] = 0;
      g_score_sell[i] = 0;
      g_score_why[i] = "-";
      g_wait_why[i] = "";
      g_signal_txt[i] = "СИГНАЛ: …";
      g_analysis[i] = "-";
      g_conf[i] = 0;
      g_signal_enter[i] = false;
      g_expected_usd[i] = 0;
      g_opp_size[i] = OPP_SMALL;
      g_align_score[i] = 0;
      g_block_reason[i] = "";
      if(g_ema_fast[i] == INVALID_HANDLE || g_ema_slow[i] == INVALID_HANDLE || g_atr[i] == INVALID_HANDLE)
        {
         PrintFormat("Индикаторы не созданы для %s", g_syms[i]);
         return INIT_FAILED;
        }
      PrintFormat("Символ: %s %s (только график)", g_syms[i], IsGoldSymbol(g_syms[i]) ? "[GOLD]" : "");
     }

   g_day_start = DayStart();
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_pnl = 0.0;
   g_day_income = 0.0;
   g_day_expense = 0.0;
   g_trades_today = 0;
   g_loss_streak = 0;

   int ms = MathMax(InpLockTimerMs, 50);
   if(!EventSetMillisecondTimer(ms))
      Print("Timer fail — LOCK только на тиках графика");

   PrintFormat("ProfitScalper v3.97 PRED | chart=%s | lot=%.2f | lock$=%.2f/%.2f | panic=$%.2f | micro-first (BUY=SELL)",
               _Symbol, InpLot, InpMinProfitMoney, InpBigProfitMoney, InpPanicCutMoney);
   g_last_pulse_ms = 0;
   g_last_signal_print_ms = 0;
   RefreshAllSignals();
   UpdatePanel();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < g_sym_count; i++)
     {
      IndicatorRelease(g_ema_fast[i]);
      IndicatorRelease(g_ema_slow[i]);
      IndicatorRelease(g_atr[i]);
     }
   ClearHud();
   Print("ProfitScalper остановлен");
  }

//+------------------------------------------------------------------+
MarketFlow FlowFor(const string sym)
  {
   return ReadMarketFlow(sym, InpLot, InpMinProfitMoney, InpMinEnterConf);
  }

//+------------------------------------------------------------------+
void PulseAlive()
  {
   if(g_sym_count <= 0) return;
   if(g_last_pulse_ms > 0 &&
      (GetTickCount64() - g_last_pulse_ms) < 10000)
      return;
   g_last_pulse_ms = GetTickCount64();

   const string sym = g_syms[0];
   MarketFlow flow = FlowFor(sym);
   int open_n = CountOurPositions(sym);
   string opp = (flow.opportunity == OPP_BIG ? "КРУПНЫЙ"
                 : (flow.opportunity == OPP_MID ? "СРЕДНИЙ" : "МЕЛКИЙ"));
   PrintFormat(
      "PULSE %s | %s conf=%.0f enter=%s opp=%s expect$=%.0f align=%d B%d/S%d open=%d | net$=%.2f приход$=%.2f расход$=%.2f | %s | %s",
      sym,
      flow.dir == ORDER_TYPE_BUY ? "BUY" : "SELL",
      flow.conf,
      flow.clear ? "YES" : "no",
      opp, flow.expected_usd, flow.align_score,
      flow.buy_v, flow.sell_v, open_n,
      g_day_pnl, g_day_income, g_day_expense,
      flow.signal_txt,
      flow.analysis);
  }

//+------------------------------------------------------------------+
// Обновляет предикт/сигнал СРАЗУ (каждый тик), даже без сделки.
void RefreshAllSignals()
  {
   for(int idx = 0; idx < g_sym_count; idx++)
     {
      const string sym = g_syms[idx];
      MarketFlow flow = FlowFor(sym);
      KnowledgeScore ks = EvaluateKnowledge(sym, InpSignalTF, true, false);

      g_score_buy[idx] = ks.buy;
      g_score_sell[idx] = ks.sell;
      g_score_why[idx] = flow.reason;
      g_pred_gap[idx] = MathAbs(ks.buy - ks.sell);
      g_conf[idx] = flow.conf;
      g_signal_txt[idx] = flow.signal_txt;
      g_analysis[idx] = flow.analysis;
      g_expected_usd[idx] = flow.expected_usd;
      g_opp_size[idx] = (int)flow.opportunity;
      g_align_score[idx] = flow.align_score;

      // Вход только если clear (BIG) — и опционально жёстко onlyBIG
      bool allow = flow.clear;
      if(InpOnlyBigOpportunity && flow.opportunity != OPP_BIG)
         allow = false;
      g_signal_enter[idx] = allow;
      g_pred_side[idx] = (flow.dir == ORDER_TYPE_BUY ? "UP/BUY" : "DOWN/SELL");
      g_pred_strong[idx] = (InpSmartBigProfit && allow && flow.conf >= InpMinEnterConf);
      g_lock_target[idx] = g_pred_strong[idx] ? InpBigProfitMoney : InpMinProfitMoney;

      if(allow)
         g_wait_why[idx] = "";
      else
         g_wait_why[idx] = StringFormat(
            "Ждём КРУПНЫЙ: bias %s conf=%.0f%% expect$=%.0f align=%d | %s",
            flow.dir == ORDER_TYPE_BUY ? "BUY" : "SELL",
            flow.conf, flow.expected_usd, flow.align_score, flow.analysis);

      if(g_last_signal_print_ms == 0 ||
         (GetTickCount64() - g_last_signal_print_ms) >= 3000)
        {
         g_last_signal_print_ms = GetTickCount64();
         PrintFormat("SIGNAL %s | %s | %s", sym, flow.signal_txt, flow.analysis);
        }
     }
   DrawSignalOnChart();
  }

//+------------------------------------------------------------------+
void HudLabel(const string name, const int y, const int fontsize,
              const string font, const color clr, const string text)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void ClearHud()
  {
   Comment(""); // больше не дублируем текст поверх лейблов
   string names[] = {"PS_SIG","PS_AN","PS_HUD0","PS_HUD1","PS_HUD2","PS_HUD3",
                     "PS_HUD4","PS_HUD5","PS_HUD6","PS_HUD7","PS_HUD8"};
   for(int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, names[i]);
  }

//+------------------------------------------------------------------+
void DrawSignalOnChart()
  {
   if(g_sym_count <= 0) return;
   const int i = 0;

   color clr_sig = clrSilver;
   string status = "ЖДЁМ";
   if(g_signal_enter[i])
     {
      status = "ВХОД";
      if(g_pred_side[i] == "UP/BUY") clr_sig = clrLime;
      else clr_sig = clrTomato;
     }
   else if(StringFind(g_pred_side[i], "BUY") >= 0) clr_sig = C'100,180,255';
   else if(StringFind(g_pred_side[i], "SELL") >= 0) clr_sig = C'255,140,90';

   string opp = "МЕЛКИЙ";
   if(g_opp_size[i] == OPP_BIG) opp = "КРУПНЫЙ";
   else if(g_opp_size[i] == OPP_MID) opp = "СРЕДНИЙ";

   string side = (StringFind(g_pred_side[i], "SELL") >= 0) ? "SELL" : "BUY";
   int open_n = CountOurPositions(g_syms[i]);

   // Компактная панель СВЕРХУ СПРАВА — не лезет на one-click и не дублирует Comment
   int y = 18;
   HudLabel("PS_HUD0", y, 11, "Segoe UI Semibold", clrWhite,
            "ProfitScalper  ·  v3.97");
   y += 20;
   HudLabel("PS_HUD1", y, 9, "Consolas", C'130,140,155',
            "────────────────────────");
   y += 18;

   // Если сигнал ВХОД, но ордера нет — показываем правду, не врут
   string head = StringFormat("%s   %s  %.0f%%", status, side, g_conf[i]);
   if(g_signal_enter[i] && open_n <= 0 && g_block_reason[i] != "")
     {
      head = "СИГНАЛ ЕСТЬ · НЕТ ОРДЕРА";
      clr_sig = clrGold;
     }
   if(g_trading_paused)
     {
      head = "ПАУЗА ДНЯ";
      clr_sig = clrOrange;
     }
   HudLabel("PS_HUD2", y, 14, "Segoe UI Semibold", clr_sig, head);
   y += 22;
   HudLabel("PS_HUD3", y, 10, "Consolas", clrSilver,
            StringFormat("%s   ~$%.0f   align %d/5", opp, g_expected_usd[i], g_align_score[i]));
   y += 18;
   HudLabel("PS_HUD4", y, 9, "Consolas", C'160,170,180',
            g_analysis[i]);
   y += 18;
   HudLabel("PS_HUD5", y, 9, "Consolas", C'130,140,155',
            "────────────────────────");
   y += 18;
   color net_clr = (g_day_pnl >= 0.0 ? C'80,220,140' : C'255,110,110');
   HudLabel("PS_HUD6", y, 11, "Segoe UI Semibold", net_clr,
            StringFormat("net  $%.2f", g_day_pnl));
   y += 18;
   HudLabel("PS_HUD7", y, 9, "Consolas", clrSilver,
            StringFormat("приход $%.2f   расход $%.2f", g_day_income, g_day_expense));
   y += 16;
   string foot = StringFormat("поз %d   lot %.2f   lock $%.0f",
                              open_n, InpLot, g_lock_target[i]);
   if(g_block_reason[i] != "")
      foot = g_block_reason[i];
   else if(g_signal_enter[i])
      foot += "   по сигналу";
   else
      foot += "   ждём КРУПНЫЙ";
   HudLabel("PS_HUD8", y, 9, "Consolas",
            (g_block_reason[i] != "" ? clrGold : C'160,170,180'), foot);

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ResetDayIfNeeded();
   RefreshAllSignals();
   PulseAlive();
   g_trading_paused = DayRiskHit();
   ManageOpenRisk();

   if(InpFarmLoop && g_trades_today < InpMaxTradesDay)
     {
      for(int i = 0; i < g_sym_count; i++)
         FarmSymbol(i);
     }
   UpdatePanel(); // HUD после попытки входа — виден BLOCK
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDayIfNeeded();
   RefreshAllSignals();
   PulseAlive();
   g_trading_paused = DayRiskHit();
   ManageOpenRisk();

   if(InpFarmLoop)
     {
      for(int i = 0; i < g_sym_count; i++)
         FarmSymbol(i);
     }
   UpdatePanel();
  }

//+------------------------------------------------------------------+
// Пауза блокирует только НОВЫЕ входы. LOCK/CUT всегда работают.
void ManageOpenRisk()
  {
   ManageAllPositions();
   for(int i = 0; i < g_sym_count; i++)
      ProtectAgainstFlow(i);
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
void LogBlock(const int idx, const string why)
  {
   g_block_reason[idx] = why;
   if(g_last_block_print_ms > 0 &&
      (GetTickCount64() - g_last_block_print_ms) < 3000)
      return;
   g_last_block_print_ms = GetTickCount64();
   PrintFormat("BLOCK %s | %s | signal=%s", g_syms[idx], why, g_signal_txt[idx]);
  }

//+------------------------------------------------------------------+
bool BrokerTradeOk(string &why)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     { why = "нет связи с сервером"; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     { why = "терминал: торговля OFF"; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     { why = "Алготорговля OFF (кнопка сверху)"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { why = "счёт ещё не разрешил торговлю (логин?)"; return false; }
   // ACCOUNT_TRADE_EXPERT на демо иногда 0 в первые секунды после старта — не блокируем им
   return true;
  }

//+------------------------------------------------------------------+
void FarmSymbol(const int idx)
  {
   const string sym = g_syms[idx];
   int open_now = CountOurPositions(sym);
   g_block_reason[idx] = "";

   if(DayRiskHit())
     {
      LogBlock(idx, StringFormat("пауза дня net$=%.2f расход$=%.2f", g_day_pnl, g_day_expense));
      return;
     }

   string why_broker = "";
   if(!BrokerTradeOk(why_broker))
     {
      LogBlock(idx, why_broker);
      return;
     }

   if(g_trades_today >= InpMaxTradesDay)
     {
      LogBlock(idx, "лимит сделок за день");
      return;
     }

   MarketScore score;
   if(!AnalyzeSymbol(idx, score))
     {
      LogBlock(idx, "нет котировок/индикаторов");
      return;
     }

   ENUM_ORDER_TYPE type = (g_pred_side[idx] == "DOWN/SELL") ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   string reason = StringFormat("%s | BIG conf=%.0f expect$=%.0f lock$=%.2f align=%d",
                                g_signal_txt[idx], g_conf[idx], g_expected_usd[idx],
                                g_lock_target[idx], g_align_score[idx]);
   bool can_trade = g_signal_enter[idx];

   if(can_trade && g_expected_usd[idx] < InpMinProfitMoney * 0.90)
     {
      LogBlock(idx, StringFormat("expect$=%.0f < lock$=%.2f", g_expected_usd[idx], InpMinProfitMoney));
      can_trade = false;
     }

   if(InpDirection == DIR_BUY)
     { type = ORDER_TYPE_BUY; can_trade = true; reason = "fixed BUY"; }
   else if(InpDirection == DIR_SELL)
     { type = ORDER_TYPE_SELL; can_trade = true; reason = "fixed SELL"; }

   if(open_now > 0 && can_trade)
     {
      int our = -1;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         our = (int)PositionGetInteger(POSITION_TYPE);
         break;
        }
      if(our >= 0)
        {
         bool mismatch = ((our == POSITION_TYPE_BUY && type == ORDER_TYPE_SELL) ||
                          (our == POSITION_TYPE_SELL && type == ORDER_TYPE_BUY));
         if(mismatch)
           {
            LogBlock(idx, "уже открыта противная сторона");
            return;
           }
        }
     }

   if(!InpRefillBasket && open_now > 0)
     {
      g_block_reason[idx] = ""; // норма: уже в рынке
      return;
     }
   if(open_now >= InpMaxPositions)
     {
      g_block_reason[idx] = "";
      return;
     }

   if(!can_trade)
     {
      // Не спамим BLOCK когда просто ждём сигнал
      g_block_reason[idx] = (StringFind(g_signal_txt[idx], "ВХОД") >= 0)
                            ? "фильтр can_trade=false"
                            : "";
      return;
     }

   if(g_pause_until_ms[idx] > 0 && GetTickCount64() < g_pause_until_ms[idx])
     {
      ulong left = (g_pause_until_ms[idx] - GetTickCount64()) / 1000;
      LogBlock(idx, StringFormat("cooldown после лосса %lluс", left));
      return;
     }

   if(g_last_farm_ms[idx] > 0 &&
      (GetTickCount64() - g_last_farm_ms[idx]) < (ulong)MathMax(InpFarmCooldownMs, 50))
     {
      // короткий кулдаун после своего же входа — не ошибка
      return;
     }

   if(InpUseSpreadFilter)
     {
      int max_spread = InpMaxSpreadPts;
      if(IsGoldSymbol(sym))
         max_spread = MathMax(max_spread, 800);
      if(score.spread_pts > (double)max_spread)
        {
         LogBlock(idx, StringFormat("спред %.0f > %d", score.spread_pts, max_spread));
         return;
        }
     }

   long trade_mode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
     {
      LogBlock(idx, "символ: торговля отключена");
      return;
     }

   int basket = MathMin(InpBasketOpen, InpMaxPositions);
   if(!g_pred_strong[idx])
      basket = 1;
   int need = MathMin(basket, InpMaxPositions - open_now);
   if(need <= 0)
      return;

   PrintFormat("TRY %s %s need=%d spread=%.0f | %s",
               sym, type == ORDER_TYPE_BUY ? "BUY" : "SELL", need, score.spread_pts, reason);

   int opened = OpenBasket(sym, type, score, reason, need);
   if(opened > 0)
     {
      g_last_farm_ms[idx] = GetTickCount64();
      g_last_dir[idx] = type;
      g_have_dir[idx] = true;
      g_wait_why[idx] = "";
      g_block_reason[idx] = "";
      PrintFormat("FARM %s: +%d %s (open=%d/%d) lot=%.2f", sym, opened,
                  type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                  open_now + opened, InpMaxPositions, LotForSymbol(sym));
     }
   else
     {
      LogBlock(idx, StringFormat("ордер отклонён ret=%d %s",
                                 trade.ResultRetcode(), trade.ResultRetcodeDescription()));
     }
  }

//+------------------------------------------------------------------+
bool AnalyzeSymbol(const int idx, MarketScore &s)
  {
   s.atr_pts = 0; s.spread_pts = 0; s.trend_up = false; s.trend_down = false;
   string sym = g_syms[idx];

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0) return false;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return false;
   s.spread_pts = (ask - bid) / point;

   // ATR: сначала кэш-хендл, при сбое — разовый iATR (после рестартов Wine часто пусто)
   double atr[];
   ArraySetAsSeries(atr, true);
   bool got_atr = false;
   if(g_atr[idx] != INVALID_HANDLE && CopyBuffer(g_atr[idx], 0, 0, 3, atr) >= 3)
     {
      s.atr_pts = atr[1] / point;
      got_atr = true;
     }
   if(!got_atr)
     {
      int h = iATR(sym, PERIOD_M15, InpATRPeriod);
      if(h != INVALID_HANDLE)
        {
         if(CopyBuffer(h, 0, 0, 3, atr) >= 3)
           {
            s.atr_pts = atr[1] / point;
            got_atr = true;
           }
         IndicatorRelease(h);
        }
     }
   if(!got_atr || s.atr_pts <= 0.0)
      s.atr_pts = MathMax(s.spread_pts * 8.0, 80.0); // запасной ATR чтобы ордера шли

   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(g_ema_fast[idx] != INVALID_HANDLE && g_ema_slow[idx] != INVALID_HANDLE &&
      CopyBuffer(g_ema_fast[idx], 0, 0, 3, fast) >= 3 &&
      CopyBuffer(g_ema_slow[idx], 0, 0, 3, slow) >= 3)
     {
      s.trend_up = (fast[1] > slow[1]);
      s.trend_down = (fast[1] < slow[1]);
     }
   else
     {
      // Тренд для panel — по живому flow, без блокировки входа
      MarketFlow fl = FlowFor(sym);
      s.trend_up = (fl.dir == ORDER_TYPE_BUY);
      s.trend_down = (fl.dir == ORDER_TYPE_SELL);
     }
   return true;
  }

//+------------------------------------------------------------------+
void UpdatePrediction(const int idx, const MarketScore &s)
  {
   KnowledgeScore ks = EvaluateKnowledge(g_syms[idx], InpSignalTF, s.trend_up, s.trend_down);
   double gap = MathAbs(ks.buy - ks.sell);
   g_pred_gap[idx] = gap;
   g_pred_strong[idx] = (InpSmartBigProfit && gap >= InpStrongScoreGap);

   if(ks.buy > ks.sell)
      g_pred_side[idx] = "UP/BUY";
   else if(ks.sell > ks.buy)
      g_pred_side[idx] = "DOWN/SELL";
   else
      g_pred_side[idx] = "TIE";

   if(g_pred_strong[idx])
     {
      g_lock_target[idx] = InpBigProfitMoney;
      PrintFormat("PRED STRONG %s %s gap=%.1f → цель $%.2f (держать ход)",
                  g_syms[idx], g_pred_side[idx], gap, g_lock_target[idx]);
     }
   else
     {
      g_lock_target[idx] = InpMinProfitMoney;
      PrintFormat("PRED soft %s %s gap=%.1f → мин $%.2f",
                  g_syms[idx], g_pred_side[idx], gap, g_lock_target[idx]);
     }
  }

//+------------------------------------------------------------------+
// true = можно открывать; false = ждём (сигнал всё равно уже в панели)
bool ResolveDir(const int idx, const MarketScore &s, ENUM_ORDER_TYPE &type, string &reason)
  {
   if(InpDirection == DIR_BUY)
     {
      type = ORDER_TYPE_BUY; reason = "fixed BUY";
      g_pred_side[idx]="UP/BUY"; g_signal_txt[idx]="СИГНАЛ: BUY (fixed)"; g_signal_enter[idx]=true;
      return true;
     }
   if(InpDirection == DIR_SELL)
     {
      type = ORDER_TYPE_SELL; reason = "fixed SELL";
      g_pred_side[idx]="DOWN/SELL"; g_signal_txt[idx]="СИГНАЛ: SELL (fixed)"; g_signal_enter[idx]=true;
      return true;
     }

   // Свежий анализ — торговля только по КРУПНОМУ сигналу
   MarketFlow flow = FlowFor(g_syms[idx]);
   KnowledgeScore ks = EvaluateKnowledge(g_syms[idx], InpSignalTF, s.trend_up, s.trend_down);
   g_score_buy[idx] = ks.buy;
   g_score_sell[idx] = ks.sell;
   g_score_why[idx] = flow.reason;
   g_pred_gap[idx] = MathAbs(ks.buy - ks.sell);
   g_conf[idx] = flow.conf;
   g_signal_txt[idx] = flow.signal_txt;
   g_analysis[idx] = flow.analysis;
   g_expected_usd[idx] = flow.expected_usd;
   g_opp_size[idx] = (int)flow.opportunity;
   g_align_score[idx] = flow.align_score;
   bool allow = flow.clear;
   if(InpOnlyBigOpportunity && flow.opportunity != OPP_BIG)
      allow = false;
   if(allow && flow.expected_usd < InpMinProfitMoney * 0.90)
      allow = false;
   g_signal_enter[idx] = allow;
   type = flow.dir;
   g_pred_side[idx] = (type == ORDER_TYPE_BUY ? "UP/BUY" : "DOWN/SELL");

   if(InpRequireClearFlow && !allow)
     {
      g_pred_strong[idx] = false;
      g_lock_target[idx] = InpMinProfitMoney;
      g_wait_why[idx] = StringFormat(
         "Ждём КРУПНЫЙ (bias %s %.0f%% ~$%.0f align=%d). %s",
         type == ORDER_TYPE_BUY ? "BUY" : "SELL", flow.conf,
         flow.expected_usd, flow.align_score, flow.analysis);
      reason = "WAIT " + flow.signal_txt + " | " + flow.reason;
      return false;
     }

   g_pred_strong[idx] = (InpSmartBigProfit && allow && flow.conf >= InpMinEnterConf);
   g_lock_target[idx] = g_pred_strong[idx] ? InpBigProfitMoney : InpMinProfitMoney;
   g_wait_why[idx] = "";
   reason = StringFormat("%s | BIG %s conf=%.0f expect$=%.0f B%d/S%d w%.1f/%.1f lock$=%.2f | %s",
                         flow.signal_txt,
                         type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                         flow.conf, flow.expected_usd, flow.buy_v, flow.sell_v,
                         flow.buy_w, flow.sell_w,
                         g_lock_target[idx],
                         flow.analysis);
   return true;
  }

//+------------------------------------------------------------------+
double BasketMoney(const string sym)
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      sum += PositionMoneyNow(ticket);
     }
   return sum;
  }

//+------------------------------------------------------------------+
int CloseOurSymbol(const string sym, const string why)
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(trade.PositionClose(ticket, InpDeviation))
         closed++;
     }
   if(closed > 0)
      PrintFormat("CUT %s x%d | %s", sym, closed, why);
   return closed;
  }

//+------------------------------------------------------------------+
int OldestOurPositionAgeSec(const string sym)
  {
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || t < oldest) oldest = t;
     }
   if(oldest == 0) return 0;
   return (int)(TimeCurrent() - oldest);
  }

//+------------------------------------------------------------------+
// Cut после grace. В grace — только panic. Пик профита защищаем в ManageOne.
void ProtectAgainstFlow(const int idx)
  {
   const string sym = g_syms[idx];
   int open_n = CountOurPositions(sym);
   if(open_n <= 0)
     {
      g_peak_money[idx] = 0.0;
      return;
     }

   double basket = BasketMoney(sym);
   if(basket > g_peak_money[idx])
      g_peak_money[idx] = basket;

   int age = OldestOurPositionAgeSec(sym);
   bool in_grace = (age < MathMax(InpCutGraceSec, 0));

   if(basket <= -MathAbs(InpPanicCutMoney))
     {
      CloseOurSymbol(sym, StringFormat("PANIC $%.2f <= -%.2f age=%ds", basket, InpPanicCutMoney, age));
      g_pause_until_ms[idx] = GetTickCount64() + (ulong)MathMax(InpLossCooldownMs, 30000);
      g_peak_money[idx] = 0.0;
      return;
     }

   if(in_grace)
      return; // дать золоту дыхание — иначе мгновенный −$ съедает lock

   // Узнать сторону позиции
   int our = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      our = (int)PositionGetInteger(POSITION_TYPE);
      break;
     }

   // Микро (M1/M5) развернулся против — режем раньше половинным cut (меньший убыток)
   if(our >= 0 && age >= 12)
     {
      MarketFlow flow_m = FlowFor(sym);
      bool buy_wrong =
         (our == POSITION_TYPE_BUY && flow_m.dir == ORDER_TYPE_SELL &&
          StringFind(flow_m.analysis, "M5:↓") >= 0 && StringFind(flow_m.analysis, "M1:↓") >= 0 &&
          flow_m.align_score >= 3);
      bool sell_wrong =
         (our == POSITION_TYPE_SELL && flow_m.dir == ORDER_TYPE_BUY &&
          StringFind(flow_m.analysis, "M5:↑") >= 0 && StringFind(flow_m.analysis, "M1:↑") >= 0 &&
          flow_m.align_score >= 3);
      double early_cut = MathAbs(InpBasketCutLoss) * 0.55;
      if((buy_wrong || sell_wrong) && basket <= -early_cut)
        {
         CloseOurSymbol(sym, StringFormat(
            "MICRO против $%.2f <= -%.2f age=%ds | %s", basket, early_cut, age, flow_m.analysis));
         g_pause_until_ms[idx] = GetTickCount64() + (ulong)MathMax(InpLossCooldownMs, 30000);
         g_peak_money[idx] = 0.0;
         return;
        }
     }

   if(basket <= -MathAbs(InpBasketCutLoss))
     {
      CloseOurSymbol(sym, StringFormat("basket loss $%.2f <= -%.2f age=%ds", basket, InpBasketCutLoss, age));
      g_pause_until_ms[idx] = GetTickCount64() + (ulong)MathMax(InpLossCooldownMs, 30000);
      g_peak_money[idx] = 0.0;
      return;
     }

   if(!InpCloseAgainstFlow)
      return;

   if(our < 0)
      return;

   MarketFlow flow = FlowFor(sym);
   bool closed_h1_vs =
      (our == POSITION_TYPE_BUY  && StringFind(flow.reason, "H1cl↓") >= 0) ||
      (our == POSITION_TYPE_SELL && StringFind(flow.reason, "H1cl↑") >= 0);

   if(closed_h1_vs && basket <= -MathAbs(InpBasketCutLoss))
     {
      CloseOurSymbol(sym, StringFormat(
         "H1cl против + cut$ basket=$%.2f | %s", basket, flow.reason));
      g_pause_until_ms[idx] = GetTickCount64() + (ulong)MathMax(InpLossCooldownMs, 30000);
      g_peak_money[idx] = 0.0;
     }
  }

//+------------------------------------------------------------------+
bool TrySendMarket(const string sym, const ENUM_ORDER_TYPE type, const double lot,
                   const double sl, const double tp, const string comment)
  {
   // Перебор filling — иначе на демо/разных символах ордер молча не проходит
   ENUM_ORDER_TYPE_FILLING fills[3];
   fills[0] = ORDER_FILLING_IOC;
   fills[1] = ORDER_FILLING_FOK;
   fills[2] = ORDER_FILLING_RETURN;
   long allowed = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   for(int i = 0; i < 3; i++)
     {
      ENUM_ORDER_TYPE_FILLING f = fills[i];
      bool ok_mode = false;
      if(f == ORDER_FILLING_FOK && (allowed & SYMBOL_FILLING_FOK) != 0) ok_mode = true;
      if(f == ORDER_FILLING_IOC && (allowed & SYMBOL_FILLING_IOC) != 0) ok_mode = true;
      if(f == ORDER_FILLING_RETURN) ok_mode = true; // часто работает даже если флаги странные
      if(!ok_mode && i < 2) continue;

      trade.SetTypeFilling(f);
      bool ok = (type == ORDER_TYPE_BUY)
                ? trade.Buy(lot, sym, 0.0, sl, tp, comment)
                : trade.Sell(lot, sym, 0.0, sl, tp, comment);
      if(ok) return true;
      PrintFormat("OPEN try fill=%d ret=%d %s", (int)f, trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
     }
   return false;
  }

//+------------------------------------------------------------------+
bool OpenTrade(const string sym, const ENUM_ORDER_TYPE type, const MarketScore &s, const string reason)
  {
   string why = "";
   if(!BrokerTradeOk(why))
     { Print("OPEN deny: ", why); return false; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);

   int idx = 0;
   for(int i = 0; i < g_sym_count; i++)
      if(g_syms[i] == sym) { idx = i; break; }

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   int stops_level = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double sl_pts = MathMax(s.atr_pts * InpATR_SL_Mult, 30.0);
   sl_pts = MathMax(sl_pts, s.spread_pts * 1.5 + 20.0);
   sl_pts = MathMax(sl_pts, (double)stops_level + 10.0);

   double rr = g_pred_strong[idx] ? InpStrongRR : InpWeakRR;
   double tp_pts = sl_pts * rr;

   double sl = 0, tp = 0;
   if(InpSendStopsAtOpen)
     {
      if(type == ORDER_TYPE_BUY)
        {
         double price = SymbolInfoDouble(sym, SYMBOL_ASK);
         sl = NormalizeDouble(price - sl_pts * point, digits);
         tp = NormalizeDouble(price + tp_pts * point, digits);
        }
      else
        {
         double price = SymbolInfoDouble(sym, SYMBOL_BID);
         sl = NormalizeDouble(price + sl_pts * point, digits);
         tp = NormalizeDouble(price - tp_pts * point, digits);
        }
     }

   double lot = NormalizeLot(sym, LotForSymbol(sym));
   string comment = StringFormat("%s %.0f>%.0f",
                                 type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                 type == ORDER_TYPE_BUY ? g_score_buy[idx] : g_score_sell[idx],
                                 type == ORDER_TYPE_BUY ? g_score_sell[idx] : g_score_buy[idx]);
   if(StringLen(comment) > 31)
      comment = StringSubstr(comment, 0, 31);

   // 1) рынок без стопов — надёжнее; лок/кат делает EA
   bool ok = TrySendMarket(sym, type, lot, 0.0, 0.0, comment);
   // 2) если попросили стопы или нулевой заход странный — ещё раз со стопами
   if(!ok && InpSendStopsAtOpen)
      ok = TrySendMarket(sym, type, lot, sl, tp, comment);
   else if(!ok)
     {
      // fallback: со стопами на случай брокера, требующего SL
      if(type == ORDER_TYPE_BUY)
        {
         double price = SymbolInfoDouble(sym, SYMBOL_ASK);
         sl = NormalizeDouble(price - sl_pts * point, digits);
         tp = NormalizeDouble(price + tp_pts * point, digits);
        }
      else
        {
         double price = SymbolInfoDouble(sym, SYMBOL_BID);
         sl = NormalizeDouble(price + sl_pts * point, digits);
         tp = NormalizeDouble(price - tp_pts * point, digits);
        }
      ok = TrySendMarket(sym, type, lot, sl, tp, comment);
     }

   if(ok)
      PrintFormat("OPEN %s %s lot=%.2f RR=%.1f lock$=%.2f | %s",
                  sym, type == ORDER_TYPE_BUY ? "BUY" : "SELL", lot, rr, g_lock_target[idx], reason);
   else
      PrintFormat("OPEN fail %s: %d %s", sym, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return ok;
  }

//+------------------------------------------------------------------+
int OpenBasket(const string sym, const ENUM_ORDER_TYPE type, const MarketScore &s,
               const string reason, const int basket)
  {
   int opened = 0;
   for(int i = 0; i < basket; i++)
     {
      if(g_trades_today >= InpMaxTradesDay) break;
      if(CountOurPositions(sym) >= InpMaxPositions) break;
      if(OpenTrade(sym, type, s, reason + StringFormat(" #%d", i + 1)))
        {
         g_trades_today++;
         opened++;
        }
      else break;
     }
   return opened;
  }

//+------------------------------------------------------------------+
double NormalizeLot(const string sym, double lot)
  {
   double min_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step_lot <= 0.0) step_lot = 0.01;
   int vol_digits = 2;
   if(step_lot >= 1.0) vol_digits = 0;
   else if(step_lot >= 0.1) vol_digits = 1;
   lot = MathFloor(lot / step_lot + 1e-12) * step_lot;
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;
   return NormalizeDouble(lot, vol_digits);
  }

//+------------------------------------------------------------------+
int CountOurPositions(const string sym = "")
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(sym != "" && PositionGetString(POSITION_SYMBOL) != sym) continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
double PositionMoneyNow(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return -1e9;
   // Floating P/L брокера
   double money = PositionGetDouble(POSITION_PROFIT)
                  + PositionGetDouble(POSITION_SWAP);

   // Только брокерский P/L. Тиковый calc на золоте занижал минус → cut резал «−$8» при реальных −$80.
   return money;
  }

//+------------------------------------------------------------------+
void ManageAllPositions()
  {
   // Копия тикетов — после Close индексы плывут
   ulong tickets[];
   ArrayResize(tickets, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = ticket;
     }

   for(int i = 0; i < ArraySize(tickets); i++)
      ManageOne(tickets[i]);
  }

//+------------------------------------------------------------------+
void ManageOne(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   string sym = PositionGetString(POSITION_SYMBOL);
   double money = PositionMoneyNow(ticket);
   double lock_at = MinProfitForSymbol(sym);

   int idx = 0;
   for(int i = 0; i < g_sym_count; i++)
      if(g_syms[i] == sym) { idx = i; break; }
   if(money > g_peak_money[idx])
      g_peak_money[idx] = money;

   // Цель достигнута — полный lock
   if(InpCloseOnProfit && InpCloseEachAlone && money >= lock_at)
     {
      if(trade.PositionClose(ticket, InpDeviation))
        {
         for(int i = 0; i < g_sym_count; i++)
            if(g_syms[i] == sym)
               g_last_farm_ms[i] = GetTickCount64();
         PrintFormat("LOCK NOW %s #%I64u +%.2f (>=%.2f) alone", sym, ticket, money, lock_at);
         g_peak_money[idx] = 0.0;
        }
      else
         PrintFormat("LOCK FAIL %s #%I64u +%.2f ret=%d %s",
                     sym, ticket, money, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }

   // Peak-lock: только после РЕАЛЬНОГО плюса (arm), и не отдаём крошки.
   // Раньше arm=$1 → +$1.2 локали, а panic −$12 съедал 6 таких.
   double arm = MathMax(InpArmLockMoney, lock_at * 0.55);
   double min_keep = MathMax(arm * 0.85, InpMinProfitMoney * 0.50);
   if(InpCloseOnProfit && g_peak_money[idx] >= arm &&
      money >= min_keep &&
      money <= g_peak_money[idx] - MathMax(0.80, arm * 0.12))
     {
      if(trade.PositionClose(ticket, InpDeviation))
        {
         PrintFormat("LOCK PEAK %s #%I64u +%.2f (peak=%.2f arm=%.2f keep>=%.2f)",
                     sym, ticket, money, g_peak_money[idx], arm, min_keep);
         g_peak_money[idx] = 0.0;
         for(int i = 0; i < g_sym_count; i++)
            if(g_syms[i] == sym)
               g_last_farm_ms[i] = GetTickCount64();
         return;
        }
     }

   // BE / trailing — только если ещё не в зоне мгновенного lock
   long type = PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(point <= 0) return;

   double sl_dist = 0;
   if(type == POSITION_TYPE_BUY && sl > 0) sl_dist = (open - sl) / point;
   if(type == POSITION_TYPE_SELL && sl > 0) sl_dist = (sl - open) / point;
   if(sl_dist <= 0) sl_dist = 100;
   double profit_pts = (type == POSITION_TYPE_BUY) ? (bid - open) / point : (open - ask) / point;
   double r_now = profit_pts / sl_dist;

   if(InpUseBreakEven && r_now >= InpBE_R)
     {
      if(type == POSITION_TYPE_BUY)
        {
         double be = NormalizeDouble(open + InpBE_OffsetPts * point, digits);
         if(sl < be) trade.PositionModify(ticket, be, tp);
        }
      else
        {
         double be = NormalizeDouble(open - InpBE_OffsetPts * point, digits);
         if(sl == 0 || sl > be) trade.PositionModify(ticket, be, tp);
        }
     }

   if(InpUseTrailing && r_now >= InpTrailStart_R)
     {
      double trail_pts = sl_dist * InpTrailATR_Mult * 0.5;
      if(type == POSITION_TYPE_BUY)
        {
         double nsl = NormalizeDouble(bid - trail_pts * point, digits);
         if(nsl > sl && nsl < bid) trade.PositionModify(ticket, nsl, tp);
        }
      else
        {
         double nsl = NormalizeDouble(ask + trail_pts * point, digits);
         if((sl == 0 || nsl < sl) && nsl > ask) trade.PositionModify(ticket, nsl, tp);
        }
     }
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;
   double deal_pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                   + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   g_day_pnl += deal_pnl;
   if(deal_pnl >= 0.0)
     {
      g_day_income += deal_pnl;
      g_loss_streak = 0;
     }
   else
     {
      g_day_expense += (-deal_pnl);
      g_loss_streak++;
      // После минуса — длинная пауза на символе (сумма важнее частоты)
      string dsym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
      for(int i = 0; i < g_sym_count; i++)
         if(g_syms[i] == dsym)
            g_pause_until_ms[i] = GetTickCount64() + (ulong)MathMax(InpLossCooldownMs, 30000);
      if(g_loss_streak >= 2)
         PrintFormat("LOSS STREAK %d | приход$=%.2f расход$=%.2f net$=%.2f — ждём cooldown",
                     g_loss_streak, g_day_income, g_day_expense, g_day_pnl);
     }
   PrintFormat("DEAL $%+.2f | приход$=%.2f расход$=%.2f net$=%.2f",
               deal_pnl, g_day_income, g_day_expense, g_day_pnl);
  }

//+------------------------------------------------------------------+
datetime DayStart()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
void ResetDayIfNeeded()
  {
   datetime start = DayStart();
   if(start == g_day_start) return;
   g_day_start = start;
   g_day_pnl = 0;
   g_day_income = 0;
   g_day_expense = 0;
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_trading_paused = false;
   g_trades_today = 0;
   g_loss_streak = 0;
   Print("Новый день — лимиты сброшены");
  }

//+------------------------------------------------------------------+
bool DayRiskHit()
  {
   if(InpMaxLossDay && g_day_pnl <= -MathAbs(InpMaxLossMoney)) return true;
   if(InpMaxLossPct && g_day_start_balance > 0)
     {
      double lim = g_day_start_balance * InpMaxLossPercent / 100.0;
      if(g_day_pnl <= -lim) return true;
     }
   // Пауза только когда net уже ушёл в минус на buffer — НЕ блокируем при ВХОД просто из-за счётчика trades
   if(InpPauseIfExpenseLeads &&
      g_day_pnl <= -MathAbs(InpExpenseLeadBuffer) &&
      g_day_expense > g_day_income + 1.0)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   // Весь HUD рисуется лейблами справа — Comment отключён (больше нет наложения)
   Comment("");
   DrawSignalOnChart();
  }
//+------------------------------------------------------------------+
