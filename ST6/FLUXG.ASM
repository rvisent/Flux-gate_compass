;*****************************************************************************
;*                                                                           *
;*                           FLUXG.ASM                                       *
;*    RV291294-010195                                                        *
;*    RV080195: interfaccia seriale                                          *
;*    RV150195-220195: modifica current sensing - modifica seriale           *
;*                                                                           *
;*  Gestione flux-gate con comando LED di direzione                          *
;*                                                                           *
;*****************************************************************************

;|===========================================================================|
;| Assembly method without linker : ast6 -l -s fluxg.asm                     |
;|===========================================================================|

	 .title "FLUXG.ASM"
	 .vers "st6210"
	 .romsize 2
	 .pp_on                   ; consente di usare .section

	 .input "6215_reg.asm"

;
; costanti
;
ncur_cnt .equ 10                  ; controllo corrente ogni 5-8 ms
cur_min  .equ 178                 ; corrisponde a circa 3.5 V in ingresso
nstabil  .equ 150                 ; stabilizza per 750-1200 ms
ini_tim  .equ 167                 ; timer iniz.: 0.5 ms (prescaler 2, 8 MHz)
watchtim .equ 0feh                ; massimo conteggio per il watchdog
ddra_set .equ 00001111b           ; ddra: tutte uscite PA0-3
ora_set  .equ 00001111b           ; ora: tutte uscite push-pull PA0-3
ddrb_set .equ 01111000b           ; ddrb: uscite PB3-6 (driver+2*integ+ser.)
firstreg .equ 95h                 ; primo registro per tx seriale
nreg     .equ 3                   ; trasmetti tre byte
;
; parole di comando per drb (readybit alto -> off)
;
intgmask .equ 11010111b           ; apre tutti gli switch dell'integratore
;driv_h  .equ 00010111b           ; drb: uscita driver alta no integratore
driv_l   .equ 01000111b           ; drb: uscita driver bassa no integratore
;driv_ha .equ 00011111b           ; drb: uscita driver alta integr. a VREF
driv_la  .equ 01001111b           ; drb: uscita driver bassa integr. a VREF
;driv_hi .equ 00110111b           ; drb: uscita driver alta si integratore
;driv_li  .equ 01100111b          ; drb: uscita driver bassa si integratore
;
; parole di comando per orb
;
ad_chx   .equ 01111100b           ; seleziona A/D canale x flux-gate
ad_chy   .equ 01111010b           ; seleziona A/D canale y flux-gate
ad_cur   .equ 01111001b           ; seleziona A/D canale current
;
; parole di comando per ior
;
int_en   .equ 10h
int_dis  .equ 0
;
; bit da RESettare per far ripartire il timer
;
tmz      .equ 7
;
; bit di dra (0,1,2 sono comando LED)
;
databit  .equ 3                   ; dato in uscita per comunicazioni
;
; bit di drb (0,1,2 sono canali A/D)
;
vrefbit  .equ 3                   ; integratore a VREF
drivbit  .equ 4                   ; comando driver
intgbit  .equ 5                   ; integratore su FLUX-GATE
readybit .equ 6                   ; flag data ready per comunicazioni
rqbit    .equ 7                   ; flag data request per comm (INPUT)
;
; variabili in RAM
; gruppo 1: uso esclusivo routine di interrupt
;
save_a   .def 84h                 ; copia dell'accumulatore per int routine
led_cnt  .def 85h                 ; contatore per accensione LED proporzionale
ad_sel   .def 86h                 ; prossimo canale da acquisire
;
; gruppo 2: scambio tra routine di interrupt e programma
;
timer_c  .def 87h                 ; conteggio da caricare sul timer
mem_drb  .def 88h                 ; copia di drb in ram
cur_cnt  .def 89h                 ; contatore per controllo corrente
direz    .def 8ah                 ; valore di angolo 0-255 [0..360) gradi
chx1     .def 8bh                 ; canale x flux-gate fase 1 (L->H)
chx2     .def 8ch                 ; canale x flux-gate fase 2 (H->L)
chy1     .def 8dh                 ; canale y flux-gate fase 1 (L->H)
chy2     .def 8eh                 ; canale y flux-gate fase 2 (H->L)
current1 .def 8fh                 ; canale monit. corrente non usato (L->H)
current2 .def 90h                 ; canale monit. corrente (H->L)
;
; gruppo 3: non usate da interrupt
;
xoset    .def 91h                 ; offset canale x
yoset    .def 92h                 ; offset canale y
stabiliz .def 93h                 ; contatore per lettura offset
result   .def 94h                 ; variabile temporanea
tx_x     .def 95h                 ; primo byte per tx seriale (7 LSB di x)
tx_y     .def 96h                 ; secondo " " (7 LSB di y)
tx_3     .def 97h                 ; ultimo " " (2 MSB di x e y + checksum)


;*****************************************************************************
;*                             PROGRAM SPACE                                 *
;*****************************************************************************
	 .section 1               ; 800h - fffh
	 .org 80h                 ; 880h

reset    ldi wdr,watchtim         ; inizializza il watchdog.
	 ldi ddra,ddra_set        ; out A0-A3
	 ldi ora,ora_set          ; push-pull A0-A3
	 ldi ddrb,ddrb_set        ; inizializza ddrb
	 ldi orb,ad_chx           ; inizializza orb e seleziona A/D chx
	 ldi drb,driv_l           ; inizializza drb (integratore off)
	 ldi mem_drb,driv_la      ; iniziamo integrando VREF
	 clr ad_sel               ; predisponi primo canale da acquisire: chx
	 ldi timer_c,ini_tim      ; conteggio iniziale timer su variabile
	 ldi tcr,ini_tim          ; ... e sul contatore
	 ldi tscr,01111001b       ; prescaler 2, int on
	 clr led_cnt              ; azzera variabile di conteggio 0-31
	 ldi cur_cnt,255          ; salta controllo corrente per 128 ms
	 ldi stabiliz,nstabil     ; inizializza loop di stabilizzazione
	 clr direz                ; azzera direz. per giro iniziale
	 ldi ior,int_en           ; abilita gli interrupt
	 reti                     ; esci dal reset, entra nel main loop
;
;****************
;*   MAIN LOOP  *
;****************
;
; regolazione della frequenza in base alla corrente
; esegui solo quando cur_cnt==0 (ogni ncur_cnt cicli)
; -> ogni 5-8 ms
;
loop     wait                     ; attendi prossimo interrupt
	 ldi wdr,watchtim         ; ricarica il watchdog
	 ld a,cur_cnt
	 jrz do_reg
	 jp skip_cur
do_reg   call cur_reg
	 ldi cur_cnt,ncur_cnt     ; prepara nuova lettura
;
; nello stesso blocco (ogni 5-8 ms) curiamo l'inizializzazione di xoset e
; yoset, da effettuare dopo 750-1200 ms con l'integratore disinserito
;
	 ld a,stabiliz            ; decrementa stabiliz fino a zero
	 jrz go_loop              ; gia' zero, non fare nulla
	 dec stabiliz
	 jrz do_avg               ; non zero dopo decremento, aspettiamo
go_loop  jp loop
do_avg   call avgxy               ; leggi offset chx,chy (passati 500-800 ms)
	 ld a,x
	 ld xoset,a
	 ld a,y
	 ld yoset,a
	 ldi ior,int_dis          ; disabilita interrupt
	 res vrefbit,mem_drb      ; d'ora in poi integriamo il FLUXGATE
	 set intgbit,mem_drb      ; preserviamo lo stato del driver
	 ldi ior,int_en           ; riabilita interrupt
	 jp loop                  ; non fare altro per questo giro
;
; calcolo dell'angolo in base alle misure del FLUXGATE
; fai girare i led durante la stabilizzazione
;
skip_cur ld a,stabiliz
	 jrz do_calc
	 inc direz                ; 0.13-0.20 s per giro
	 jp loop                  ; salta il calcolo
do_calc  call calcola
;
; se richiesta da seriale, rispondi
;
	 jrs rqbit,drb,loop       ; no richiesta, torna al main loop
	 call prep_tx             ; elabora i tre byte
	 call txdata
	 jp loop                  ; continua


;*****************************************************************************
;* timer interrupt (max 177 cicli = 287.63 us)                               *
;*****************************************************************************
timer    ld save_a,a              ; salva a
	 ld a,timer_c             ; conteggio corrente timer
	 ld tcr,a                 ; riattiva il timer
	 res tmz,tscr
;
; accendiamo l'integratore e commutiamo il driver
; l'integratore si accende verso VREF nei primi 750-1200 ms per
; consentire la misura di xoset, yoset
;
	 jrr drivbit,mem_drb,set_dr     ; complementa drivbit
	 res drivbit,mem_drb
	 jrc res_dr
set_dr   set drivbit,mem_drb
	 jrnc res_dr              ; equalizza tempo di esecuzione
res_dr   ld a,mem_drb             ; contiene la scelta integ/vref
	 ld drb,a                 ; carica il nuovo valore
;
; mentre attendiamo i circa 42 us di integrazione,
; scegliamo il LED da accendere in base alla direzione 0-255
; sommiamo un numero variabile da 0 a 15 e poi usiamo i 3 bit
; piu' significativi, cosi' distribuiamo l'indicazione su due LED
; contigui in maniera proporzionale
;
	 ld a,led_cnt             ; incrementa generatore sequenza 0-15
	 addi a,7                 ; non 1, cosi' la sequenza e' mischiata
	 ld led_cnt,a             ; teniamo 0-255 nella variabile
;
; continuiamo dopo, adesso spegnamo l'integratore e facciamo partire A/D
;
	 ld a,mem_drb
	 andi a,intgmask          ; azzera i bit intgbit e vrefbit
	 nop                      ; ancora un po' di attesa
	 ld drb,a                 ; 42.25 us di integraz. (26 cicli @ 8 MHz)
	 ldi adcr,00110000b       ; start A/D senza interrupt
;
; riprendiamo il calcolo dei LED
;
	 ld a,led_cnt
	 andi a,15                ; porta a 0-15
	 add a,direz              ; somma la direzione da visualizzare
	 rlc a                    ; sposta i 3 MSB sui 3 LSB
	 rlc a
	 rlc a
	 rlc a
	 andi a,7                 ; azzera il resto
	 jrr databit,dra,dat0     ; rispetta databit in PA3
	 set databit,a
dat0     ld dra,a                 ; copia su PA0-PA2 (mantiene PA3)
;
; se cur_cnt e' diverso da zero, decrementalo
;
	 ld a,cur_cnt
	 jrz no_decr
	 dec cur_cnt
;
; attendiamo fine conversione A/D e memorizziamo il risultato
; (dovrebbe essere gia' terminata)
;
no_decr  ld a,ad_sel              ; cerca canale selezionato
	 jrnz ch1_5               ; no canale 0, salta
	 inc ad_sel               ; predisponi canale successivo
wt_ad0   jrr 6,adcr,wt_ad0        ; attendi fine conversione
	 ld a,adr                 ; leggi il risultato
	 ld chx1,a                ; copia in ram (DRIVER L->H)
	 ldi orb,ad_chx           ; prossimo ancora canale x flux-gate
	 jp ad_done               ; finito
ch1_5    cpi a,1
	 jrnz ch2_5               ; no canale 1, salta
	 inc ad_sel               ; predisponi canale successivo
wt_ad1   jrr 6,adcr,wt_ad1        ; attendi fine conversione
	 ld a,adr                 ; leggi il risultato
	 ld chx2,a                ; copia in ram (DRIVER H->L)
	 ldi orb,ad_chy           ; prossimo canale y flux-gate
	 jp ad_done               ; finito
ch2_5    cpi a,2
	 jrnz ch3_5               ; no canale 2, salta
	 inc ad_sel               ; predisponi canale successivo
wt_ad2   jrr 6,adcr,wt_ad2        ; attendi fine conversione
	 ld a,adr                 ; leggi il risultato
	 ld chy1,a                ; copia in ram (DRIVER L->H)
	 ldi orb,ad_chy           ; prossimo ancora canale y flux-gate
	 jp ad_done               ; finito
ch3_5    cpi a,3
	 jrnz ch4_5               ; no canale 3, salta
	 inc ad_sel               ; predisponi canale successivo
wt_ad3   jrr 6,adcr,wt_ad3        ; attendi fine conversione
	 ld a,adr                 ; leggi il risultato
	 ld chy2,a                ; copia in ram (DRIVER H->L)
	 ldi orb,ad_cur           ; prossimo canale current
	 jp ad_done               ; finito
ch4_5    cpi a,4
	 jrnz ch5                 ; no canale 4, salta al 5
	 inc ad_sel               ; predisponi canale successivo
wt_ad4   jrr 6,adcr,wt_ad4        ; attendi fine conversione
	 ld a,adr                 ; leggi il risultato
	 ld current1,a            ; copia in ram (DRIVER L->H)
	 ldi orb,ad_cur           ; prossimo canale ancora current
	 jp ad_done               ; finito
ch5      clr ad_sel               ; predisponi canale 0
wt_ad5   jrr 6,adcr,wt_ad5        ; attendi fine conversione
	 ld a,adr                 ; leggi il risultato
	 ld current2,a            ; copia in ram (DRIVER H->L)
	 ldi orb,ad_chx           ; prossimo canale x flux-gate

ad_done  ld a,save_a              ; recupera a ed esci
	 reti


;*****************************************************************************
;* Regolaz. della frequenza di comando FLUXGATE per stabilizzare la corrente *
;* usa current2 perche' la transizione H->L e' quella che segue l'impulso    *
;*   rettificato, senza una scarica significativa del condensatore;          *
;* controlliamo solo che la corrente non scenda sotto al minimo, perche'     *
;*   purtroppo sono possibili (e frequenti) picchi oltre tale valore, dovuti *
;*   alla aleatorieta' della risposta all'interrupt. D'altra parte interessa *
;*   proprio assicurare la saturazione, mentre la sovrasaturazione non pre-  *
;*   occupa. Purtroppo cosi' non si compensa una tensione di alimentazione   *
;*   in salita (ma e' atipico, quel che conta e' compensare la scarica della *
;*   batteria, un alimentatore si suppone stabilizzato!).
;*****************************************************************************
cur_reg   ld a,current2
	  cpi a,cur_min 
	  jrnc cur_ok             ; corrente sufficiente, esci
	  inc timer_c             ; rallenta il timer
cur_ok    ret
;
; test con frequenza regolabile dall'esterno con trimmer
;
;cur_reg   ld a,current2
;          rlc a                   ; dividi per 4
;          rlc a
;          rlc a
;          rlc a
;          rlc a
;          rlc a
;          rlc a
;          andi a,3fh
;          addi a,192
;          ld timer_c,a            ; timer_c = current/4 + 192
;          ret


;*****************************************************************************
;* Calcolo della direzione del campo magnetico impresso                      *
;* direz=0..255: un angolo giro                                              *
;* modifica a,x,y,v,w,result                                                 *
;*****************************************************************************
calcola  call avgxy               ; calcola x medio e y medio
	 ld a,y                   ; togli gli offset
	 sub a,yoset
	 ld y,a
	 ld tx_y,a                ; predisponi per eventuale tx seriale
	 clr tx_3                 ; inizializza tx_3=0
	 jrnc noripy
	 set 3,tx_3               ; y[8] -> tx_3[3] (bit di segno y)
noripy   ld a,x
	 sub a,xoset
	 ld x,a
	 ld tx_x,a                ; predisponi per eventuale tx seriale
	 jrnc noripx
	 set 1,tx_3               ; x[8] -> tx_3[1] (bit di segno x)
;
; cerca il quadrante v=0,1,2,3 e rendi x,y positivi
;
noripx   jrr 7,x,x_pos            ; x positivo, salta
	 com a                    ; esegui complem. a 2 (era a=x)
	 addi a,1
	 ld x,a                   ; ora x e' positivo
	 jrs 7,y,y_neg            ; y negativo, quadrante 2 
	 ldi v,1                  ; y positivo, quadrante 1
	 jp quad_ok
y_neg    ldi v,2
	 jp inv_y                 ; quad ok, occorre invertire y
x_pos    jrr 7,y,y_pos            ; y positivo, quadrante 0
	 ldi v,3                  ; y negativo, quadrante 3
inv_y    ld a,y                   ; inverti y
	 com a
	 addi a,1
	 ld y,a
	 jp quad_ok
y_pos    ldi v,0
;
; ora cerca l'ottante: 0 se x>=y, 1 altrimenti.
; scambia x,y se ottante 1. Metti flag ottante in v(7)
;
quad_ok  ld a,x
	 sub a,y
	 jrnc ott0                ; y<=x -> ottante 0
	 ld a,y                   ; scambia x,y
	 ld result,a              ; var temporanea
	 ld a,x
	 ld y,a
	 ld a,result
	 ld x,a
	 set 7,v                  ; segnala ottante 1
;
; ora calcoliamo l'angolo nell'ottante (0..32) mediante ang=32*y/x
; OPERAZIONE TRA NUMERI POSITIVI!
;
ott0     ldi w,6                  ; 6 bit da calcolare: 000000b-100000b
	 clr result
divloop  ld a,y                   ; numeratore
	 sub a,x                  ; risulta bit=1 se il risultato e >=0
	 jrz zer_diff
	 jrc d_gt_n               ; risultato < 0 va scartato e bit=0
zer_diff ld y,a                   ; ricarica in y la differenza
	 set 0,result             ; accendi bit nel risultato
d_gt_n   ld a,y                   ; ricarica in y il numeratore shiftato
	 sla a
	 ld y,a 
	 dec w                    ; conta i 5 bit del risultato
	 jrz divdone
	 ld a,result              ; shifta risultato a sx
	 sla a
	 ld result,a
	 jp divloop               ; prossimo bit
;
; ora ricostruiamo l'angolo in tutto il suo range
;
divdone  jrr 7,v,otta0            ; ottante 0
	 res 7,v                  ; ottante 1, ripristina v=quadrante
	 ldi a,64                 ; angolo nel quadrante = 64-result
	 sub a,result
	 ld result,a
otta0    ld a,v                   ; agisci secondo il quadrante
	 jrnz quad1_3  
	 ld a,result              ; quadrante 0, nulla da fare    
	 jp ottdone
quad1_3  cpi a,1
	 jrnz quad2_3
	 ldi a,128                ; quadrante 1, angolo = 128-result
	 sub a,result
	 jp ottdone
quad2_3  cpi a,2
	 jrnz quad3
	 ldi a,128                ; quadrante 2, angolo = 128+result
	 add a,result
	 jp ottdone
quad3    ldi a,0                  ; quadrante 3, angolo = -result
	 sub a,result
ottdone  ld result,a
;
; ora correggiamo per avere visualizzazione corretta sui LED
; cambio di direzione con shift di 90 gradi
; infine aggiungiamo 8 perche' il visualizzatore somma 0..15 e divide per 32
; (vedi interrupt). Noi vogliamo ARROTONDAMENTO -> somma media 16
; 64-dato+8 = 72-dato
;
	 ldi a,72
	 sub a,result
	 ld direz,a               ; dato per i LED
	 ret


;*****************************************************************************
;* Lettura delle medie chx, chy sui due cicli consecutivi                    *
;* risultati in x e y                                                        *
;*****************************************************************************
avgxy    ld a,chx1                ; media chx1, chx2
	 add a,chx2               ; MSB e' nel carry
	 rlc a                    ; shift a dx di un posto
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 ld x,a
	 ld a,chy1                ; media chy1, chy2
	 add a,chy2               ; MSB e' nel carry
	 rlc a                    ; shift a dx di un posto
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 rlc a
	 ld y,a
	 ret


;*****************************************************************************
;* prepara i 3 byte per la trasmissione seriale                              *
;* elabora i 3 byte (sopprimi MSB di tx_x e tx_y, accendilo in tx_3,         *
;*  calcola checksum)                                                        *
;* modifica a,x,y                                                            *
;*****************************************************************************
prep_tx  jrr 7,tx_x,x7is0
	 set 0,tx_3               ; sposta x[7] in tx_3[0]
	 res 7,tx_x               ; tx_x[7]=0
x7is0    jrr 7,tx_y,y7is0
	 set 2,tx_3               ; sposta y[7] in tx_3[2]
	 res 7,tx_y               ; tx_y[7]=0
y7is0    ld a,tx_x                ; s = x+y+x_3 (tutti e tre con MSB=0)
	 add a,tx_y
	 add a,tx_3
	 ld x,a                   ; checksum = (s+(s<<3)+(s<<6)) & 0x70
	 sla a
	 sla a
	 sla a
	 ld y,a
	 sla a
	 sla a
	 sla a
	 add a,x
	 add a,y
	 andi a,70h
	 add a,tx_3              ; aggiungi ai bit gia' in tx_3
	 set 7,a                 ; accendi MSB per marcare il terzo byte
	 ld tx_3,a
	 ret


;*****************************************************************************
;* Trasmissione di un pacchetto di dati per via seriale                      *
;* trasmette nreg byte a partire da firstreg                                 *
;* modifica a,x,y,v,w,result                                                 *
;*****************************************************************************
txdata   ldi x,firstreg           ; punta al primo byte
	 ldi w,nreg               ; numero di byte da trasmettere
nextbyte ldi y,8                  ; bit per byte
	 ld a,(x)                 ; carica il byte
;
; loop se rqbit non e' giu'. Max 6.2 ms
;
nextbit  ldi result,255
bitloop1 jrr rqbit,drb,rq_ok
	 dec result
	 ldi wdr,watchtim         ; ricarica il watchdog (e' a rischio!)
	 jrnz bitloop1
	 jp readylow              ; timeout, esci

rq_ok    sla a                    ; metti MSB in carry
	 ld v,a                   ; salva il resto
	 jrc tx_1                 ; vai a trasmettere uno
	 res databit,dra          ; trasmetti uno zero
	 jrnc tx_0
tx_1     set databit,dra          ; trasmetti un uno
tx_0     ldi ior,int_dis          ; disabilita interrupt
	 res readybit,mem_drb     ; segnala bit valido (abbassa readybit)
	 ld a,mem_drb             ; copia anche su drb
	 andi a,intgmask          ; non accendere l'integratore!
	 ld drb,a
	 ldi ior,int_en           ; riabilita interrupt
;
; ora loop finche' rqbit torna su. Esci se timeout (circa 6.2 ms)
;
	 ldi result,255
bitloop  jrs rqbit,drb,bitdone
	 dec result
	 ldi wdr,watchtim         ; ricarica il watchdog (e' a rischio!)
	 jrnz bitloop
;
; timeout, alza readybit ed esci
;
readylow ldi ior,int_dis          ; disabilita interrupt
	 set readybit,mem_drb
	 ld a,mem_drb
	 andi a,intgmask          ; non accendere l'integratore!
	 ld drb,a
	 ldi ior,int_en           ; riabilita interrupt
txdone   ret
bitdone  call readylow            ; abbassa readybit (tricky)
	 dec y                    ; prossimo bit
	 jrz bytedone
	 ld a,v                   ; ricarica a shiftato
	 jp nextbit
bytedone inc x                    ; prossimo byte
	 dec w
	 jrz txdone
	 jp nextbyte


;*****************************************************************************
;*                     Restart and interrupt Vectors                         *
;*****************************************************************************
	 .section 32              ; ff0h - fffh
	 .org 00h
iadc     reti                     ; causa solo uscita dal wait
	 reti
itimer   jp timer
int2     reti
	 reti
int1     reti
	 reti
	 
	 .org 0ch                 ; ffch
inmi     reti
	 reti
res      jp reset
