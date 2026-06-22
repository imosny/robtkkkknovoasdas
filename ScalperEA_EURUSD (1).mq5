//+------------------------------------------------------------------+
//|                                          ScalperEA_EURUSD.mq5     |
//|  EA EUR/USD - H1 - Rotina de 1 trade/dia                          |
//|                                                                     |
//|  Estratégia:                                                       |
//|   - Filtro de tendência: EMA(200)                                  |
//|   - Sinal de entrada: RSI(14) + Bandas de Bollinger(20,2)          |
//|     -> Compra: preço toca/fecha abaixo da banda inferior,          |
//|        RSI em sobrevenda, E preço acima da EMA200 (tendência alta) |
//|     -> Venda: preço toca/fecha acima da banda superior,            |
//|        RSI em sobrecompra, E preço abaixo da EMA200 (tendência     |
//|        baixa)                                                      |
//|   - SL/TP dinâmicos baseados em ATR                                |
//|   - Lote calculado por % de risco do saldo da conta (0.5% default) |
//|   - Trailing stop baseado em ATR                                   |
//|   - Limite de perda diária (% do saldo) bloqueia novas entradas    |
//|   - Filtro de spread máximo                                        |
//|   - Máximo 1 trade por dia (independente de SL/TP ter batido)      |
//|   - Filtro de horário de sessão (janela em horário de Nova York)   |
//|   - Filtro de dia da semana (não opera sábado/domingo)             |
//|   - Filtro de notícias de alto impacto (calendário econômico MT5)  |
//|   - Filtro de volatilidade (ATR atual vs média do ATR)             |
//|                                                                     |
//|  ATENÇÃO / LIMITAÇÕES CONHECIDAS:                                  |
//|   - O filtro de notícias depende do calendário econômico do        |
//|     terminal MT5 estar sincronizado. Em alguns testes do Strategy  |
//|     Tester offline, o histórico de calendário pode não estar       |
//|     disponível - teste em conta demo/real antes de confiar 100%.   |
//|   - O offset NY é configurável manualmente (InpGMTOffsetToNY)      |
//|     porque varia por corretor e por horário de verão dos EUA.      |
//|     Confira no site do seu corretor ou comparando os horários.     |
//+----------------------------------------------------------------------+
#property copyright "Gerado com Claude"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

// Timeframe de operação do EA (alterado de M15 para H1 conforme rotina de operações)
#define PERIOD_OP PERIOD_H1

//==================== INPUTS ====================

input group "=== Geral ==="
input ulong   InpMagicNumber        = 20260622;  // Número mágico (identifica trades deste EA)
input int     InpMaxPositions       = 1;         // Máximo de posições abertas simultâneas

input group "=== Indicadores ==="
input int     InpRSIPeriod          = 14;        // Período do RSI
input double  InpRSIOversold        = 30.0;      // Nível de sobrevenda do RSI
input double  InpRSIOverbought      = 70.0;      // Nível de sobrecompra do RSI
input int     InpBBPeriod           = 20;        // Período das Bandas de Bollinger
input double  InpBBDeviation        = 2.0;       // Desvio padrão das Bandas de Bollinger
input int     InpEMATrendPeriod     = 200;       // Período da EMA de tendência de fundo

input group "=== Stop Loss / Take Profit (ATR) ==="
input int     InpATRPeriod          = 14;        // Período do ATR
input double  InpATR_SL_Multiplier  = 1.5;        // Multiplicador do ATR para Stop Loss
input double  InpRiskReward         = 1.5;        // Relação Risco:Retorno (TP = SL * este valor)

input group "=== Trailing Stop (ATR) ==="
input bool    InpUseTrailing        = true;       // Usar trailing stop?
input double  InpATR_TrailStart     = 1.0;        // Lucro em múltiplos de ATR para ativar o trailing
input double  InpATR_TrailStep      = 1.0;        // Distância do trailing em múltiplos de ATR

input group "=== Gestão de Risco ==="
input double  InpRiskPercent        = 0.5;        // % do saldo arriscado por operação
input double  InpDailyLossLimitPct  = 3.0;        // % máxima de perda diária (bloqueia novas entradas)
input int     InpMaxTradesPerDay    = 1;          // Máximo de trades abertos por dia (rotina: 1/dia)

input group "=== Filtro de Spread ==="
input double  InpMaxSpreadPips      = 2.5;        // Spread máximo permitido (em pips) para nova entrada

input group "=== Filtro de Horário (sessão Londres-NY) ==="
input bool    InpUseSessionFilter   = true;       // Usar filtro de horário de sessão?
input int     InpSessionStartHourNY = 8;          // Hora de início da sessão (horário de Nova York, 0-23)
input int     InpSessionEndHourNY   = 17;         // Hora de fim da sessão (horário de Nova York, 0-23)
input int     InpGMTOffsetToNY      = 0;          // Offset (horas) do servidor do corretor MENOS NY. Ex: se o servidor está 7h na frente de NY, use 7. AJUSTE conforme seu corretor / horário de verão dos EUA.

input group "=== Filtro de Dia da Semana ==="
input bool    InpUseWeekdayFilter   = true;       // Bloquear sábado e domingo?

input group "=== Filtro de Notícias (Calendário Econômico MT5) ==="
input bool    InpUseNewsFilter      = true;       // Usar filtro de notícias de alto impacto?
input int     InpNewsMinutesBefore  = 30;          // Minutos ANTES do evento para bloquear entradas
input int     InpNewsMinutesAfter   = 30;          // Minutos DEPOIS do evento para bloquear entradas

input group "=== Filtro de Volatilidade (ATR) ==="
input bool    InpUseVolatilityFilter = true;       // Só operar se o mercado estiver "vivo"?
input int     InpATR_AvgPeriod       = 20;         // Quantidade de períodos do ATR usados para calcular a média
input double  InpATR_MinPctOfAvg     = 80.0;       // ATR atual deve ser >= este % da média do ATR (ex: 80%)

//==================== VARIÁVEIS GLOBAIS ====================

int      hRSI, hBB, hEMA, hATR;
double   PipSize;          // tamanho do pip (considera contas de 5 e 3 dígitos)
datetime g_lastBarTime = 0;
double   g_dayStartBalance = 0.0;
int      g_currentDay = -1;
bool     g_dailyLimitHit = false;
int      g_tradesToday = 0;       // contador de trades abertos no dia atual

//+------------------------------------------------------------------+
int OnInit()
  {
   PipSize = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;

   hRSI = iRSI(_Symbol, PERIOD_OP, InpRSIPeriod, PRICE_CLOSE);
   hBB  = iBands(_Symbol, PERIOD_OP, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hEMA = iMA(_Symbol, PERIOD_OP, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, PERIOD_OP, InpATRPeriod);

   if(hRSI == INVALID_HANDLE || hBB == INVALID_HANDLE || hEMA == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Erro ao criar handles dos indicadores.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   ResetDailyTracking();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hRSI);
   IndicatorRelease(hBB);
   IndicatorRelease(hEMA);
   IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
//| Reseta o controle de perda diária no início de um novo dia       |
//+------------------------------------------------------------------+
void ResetDailyTracking()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_currentDay = dt.day_of_year;
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyLimitHit = false;
   g_tradesToday = 0;
  }

//+------------------------------------------------------------------+
//| Verifica se um novo dia começou e atualiza o controle de perda   |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_currentDay)
      ResetDailyTracking();
  }

//+------------------------------------------------------------------+
//| Verifica se o limite de perda diária foi atingido                |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
  {
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pnlPercent = (currentBalance - g_dayStartBalance) / g_dayStartBalance * 100.0;

   if(pnlPercent <= -InpDailyLossLimitPct)
     {
      if(!g_dailyLimitHit)
         Print("Limite de perda diária atingido (", DoubleToString(pnlPercent,2), "%). Bloqueando novas entradas até o próximo dia.");
      g_dailyLimitHit = true;
     }

   return(g_dailyLimitHit);
  }

//+------------------------------------------------------------------+
//| Conta quantas posições deste EA/símbolo estão abertas             |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            count++;
        }
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Verifica se o spread atual está dentro do limite permitido       |
//+------------------------------------------------------------------+
bool IsSpreadOK()
  {
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPips = spreadPoints * _Point / PipSize;
   return(spreadPips <= InpMaxSpreadPips);
  }

//+------------------------------------------------------------------+
//| Converte a hora atual do servidor para a hora de Nova York (NY)  |
//| usando o offset configurado manualmente em InpGMTOffsetToNY      |
//+------------------------------------------------------------------+
int GetCurrentHourNY()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int hourNY = dt.hour - InpGMTOffsetToNY;

   // normaliza para o intervalo 0-23
   hourNY = hourNY % 24;
   if(hourNY < 0)
      hourNY += 24;

   return(hourNY);
  }

//+------------------------------------------------------------------+
//| Verifica se o horário atual (NY) está dentro da janela permitida |
//+------------------------------------------------------------------+
bool IsWithinSessionHours()
  {
   if(!InpUseSessionFilter)
      return(true);

   int hourNY = GetCurrentHourNY();

   if(InpSessionStartHourNY <= InpSessionEndHourNY)
     {
      // janela "normal", ex: 8h às 17h
      return(hourNY >= InpSessionStartHourNY && hourNY < InpSessionEndHourNY);
     }
   else
     {
      // janela que cruza a meia-noite, ex: 22h às 5h (suportado por segurança, não é o caso atual)
      return(hourNY >= InpSessionStartHourNY || hourNY < InpSessionEndHourNY);
     }
  }

//+------------------------------------------------------------------+
//| Verifica se hoje é sábado ou domingo (bloqueia novas entradas)   |
//+------------------------------------------------------------------+
bool IsWeekdayOK()
  {
   if(!InpUseWeekdayFilter)
      return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // dt.day_of_week: 0=domingo, 6=sábado
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Verifica se há evento de alto impacto (USD/EUR) próximo no       |
//| calendário econômico do MT5, dentro da janela configurada        |
//+------------------------------------------------------------------+
bool IsNewsBlocking()
  {
   if(!InpUseNewsFilter)
      return(false);

   datetime now = TimeCurrent();
   datetime windowStart = now - InpNewsMinutesBefore * 60;
   datetime windowEnd   = now + InpNewsMinutesAfter  * 60;

   string currencies[2] = {"USD", "EUR"};

   for(int c = 0; c < 2; c++)
     {
      MqlCalendarValue values[];

      // Busca eventos no intervalo de tempo relevante para a moeda
      int total = CalendarValueHistory(values, windowStart, windowEnd, NULL, currencies[c]);
      if(total <= 0)
         continue;

      for(int i = 0; i < total; i++)
        {
         MqlCalendarEvent evt;
         if(!CalendarEventById(values[i].event_id, evt))
            continue;

         if(evt.importance == CALENDAR_IMPORTANCE_HIGH)
           {
            Print("Filtro de notícias: evento de alto impacto (", currencies[c], ") próximo - ", evt.name,
                  " em ", TimeToString(values[i].time, TIME_DATE|TIME_MINUTES), ". Bloqueando novas entradas.");
            return(true);
           }
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Verifica se a volatilidade atual (ATR) é suficiente para operar  |
//| Compara o ATR atual com a média dos últimos InpATR_AvgPeriod     |
//+------------------------------------------------------------------+
bool IsVolatilityOK(double atrCurrent)
  {
   if(!InpUseVolatilityFilter)
      return(true);

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);

   // Pega o histórico do ATR (a partir da barra fechada anterior, índice 1) para calcular a média
   if(CopyBuffer(hATR, 0, 1, InpATR_AvgPeriod, atrBuf) < InpATR_AvgPeriod)
      return(false); // dados insuficientes -> não opera, por segurança

   double sum = 0.0;
   for(int i = 0; i < InpATR_AvgPeriod; i++)
      sum += atrBuf[i];

   double atrAvg = sum / InpATR_AvgPeriod;
   if(atrAvg <= 0)
      return(false);

   double minRequired = atrAvg * (InpATR_MinPctOfAvg / 100.0);

   return(atrCurrent >= minRequired);
  }

//+------------------------------------------------------------------+
//| Calcula o tamanho do lote baseado no % de risco e na distância   |
//| do Stop Loss                                                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0 || tickValue <= 0)
      return(0.0);

   double moneyPerPriceUnit = tickValue / tickSize;
   double lossPerLot = slDistancePrice * moneyPerPriceUnit;

   if(lossPerLot <= 0)
      return(0.0);

   double lots = riskAmount / lossPerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return(lots);
  }

//+------------------------------------------------------------------+
//| Gerencia o trailing stop das posições abertas deste EA           |
//+------------------------------------------------------------------+
void ManageTrailingStop(double atrValue)
  {
   if(!InpUseTrailing)
      return;

   double trailStartDist = atrValue * InpATR_TrailStart;
   double trailStepDist  = atrValue * InpATR_TrailStep;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber)
         continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double curSL     = posInfo.StopLoss();
      double curTP     = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDist = bid - openPrice;

         if(profitDist >= trailStartDist)
           {
            double newSL = bid - trailStepDist;
            newSL = NormalizeDouble(newSL, _Digits);
            if(newSL > curSL || curSL == 0)
              {
               trade.PositionModify(ticket, newSL, curTP);
              }
           }
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDist = openPrice - ask;

         if(profitDist >= trailStartDist)
           {
            double newSL = ask + trailStepDist;
            newSL = NormalizeDouble(newSL, _Digits);
            if(newSL < curSL || curSL == 0)
              {
               trade.PositionModify(ticket, newSL, curTP);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Função principal - executada em cada tick                        |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckNewDay();

   // Gerencia trailing stop a cada tick (não precisa esperar nova barra)
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 0, 1, atrBuf) > 0)
      ManageTrailingStop(atrBuf[0]);

   // O sinal de entrada só é avaliado uma vez por barra nova (H1)
   datetime currentBarTime = iTime(_Symbol, PERIOD_OP, 0);
   if(currentBarTime == g_lastBarTime)
      return;
   g_lastBarTime = currentBarTime;

   // Bloqueios para novas entradas
   if(IsDailyLossLimitHit())
      return;
   if(!IsSpreadOK())
      return;
   if(CountOpenPositions() >= InpMaxPositions)
      return;
   if(g_tradesToday >= InpMaxTradesPerDay)
      return;
   if(!IsWeekdayOK())
      return;
   if(!IsWithinSessionHours())
      return;
   if(IsNewsBlocking())
      return;

   // Lê os indicadores na barra fechada anterior (índice 1)
   double rsiBuf[], bbUpperBuf[], bbLowerBuf[], emaBuf[];
   ArraySetAsSeries(rsiBuf, true);
   ArraySetAsSeries(bbUpperBuf, true);
   ArraySetAsSeries(bbLowerBuf, true);
   ArraySetAsSeries(emaBuf, true);

   if(CopyBuffer(hRSI, 0, 0, 3, rsiBuf) < 3) return;
   if(CopyBuffer(hBB, 1, 0, 3, bbUpperBuf) < 3) return; // banda superior
   if(CopyBuffer(hBB, 2, 0, 3, bbLowerBuf) < 3) return; // banda inferior
   if(CopyBuffer(hEMA, 0, 0, 3, emaBuf) < 3) return;
   if(CopyBuffer(hATR, 0, 0, 3, atrBuf) < 3) return;

   double closePrev = iClose(_Symbol, PERIOD_OP, 1);
   double rsiPrev   = rsiBuf[1];
   double bbUpPrev  = bbUpperBuf[1];
   double bbLowPrev = bbLowerBuf[1];
   double emaPrev   = emaBuf[1];
   double atrPrev   = atrBuf[1];

   bool isUptrend   = closePrev > emaPrev;
   bool isDowntrend = closePrev < emaPrev;

   bool buySignal  = isUptrend   && closePrev <= bbLowPrev && rsiPrev <= InpRSIOversold;
   bool sellSignal = isDowntrend && closePrev >= bbUpPrev  && rsiPrev >= InpRSIOverbought;

   if(!buySignal && !sellSignal)
      return;

   // Filtro de volatilidade: só opera se o mercado estiver "vivo" (ATR atual relevante vs média)
   if(!IsVolatilityOK(atrPrev))
      return;

   if(buySignal)
      OpenPosition(ORDER_TYPE_BUY, atrPrev);
   else if(sellSignal)
      OpenPosition(ORDER_TYPE_SELL, atrPrev);
  }

//+------------------------------------------------------------------+
//| Abre uma posição com SL/TP calculados via ATR e lote via risco   |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType, double atrValue)
  {
   double slDistance = atrValue * InpATR_SL_Multiplier;
   double tpDistance = slDistance * InpRiskReward;

   double lots = CalculateLotSize(slDistance);
   if(lots <= 0)
     {
      Print("Lote calculado inválido, ordem não enviada.");
      return;
     }

   double price, sl, tp;
   bool   sent = false;

   if(orderType == ORDER_TYPE_BUY)
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = NormalizeDouble(price - slDistance, _Digits);
      tp = NormalizeDouble(price + tpDistance, _Digits);
      sent = trade.Buy(lots, _Symbol, price, sl, tp, "ScalperEA Buy");
     }
   else
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = NormalizeDouble(price + slDistance, _Digits);
      tp = NormalizeDouble(price - tpDistance, _Digits);
      sent = trade.Sell(lots, _Symbol, price, sl, tp, "ScalperEA Sell");
     }

   if(sent)
      g_tradesToday++;
   else
      Print("Falha ao enviar ordem. Retcode: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
