#include <Trade/Trade.mqh>
bool g_done = false;
int OnInit()
  {
   EventSetTimer(1);
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r){ EventKillTimer(); }
void OnTimer()
  {
   if(g_done) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   CTrade t;
   t.SetExpertMagicNumber(26071470);
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != 26071470) continue;
      if(StringFind(PositionGetString(POSITION_SYMBOL), "XAU") < 0) continue;
      if(t.PositionClose(ticket)) closed++;
     }
   Print("CloseGoldOnce: closed ", closed, " positions");
   g_done = true;
  }
void OnTick(){}
