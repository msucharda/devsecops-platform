---
name: grilling
description: "Prověř návrh otázkami na rozhodnutí, závislosti a konkrétní scénáře."
---

# Grilling

Veď návrhový strom: rozhodnutí odblokuje otázky, které na něm závisí.
Aktuální session vede rozhovor a průběžně rozlišuje ověřená fakta, návrhy,
přijatá rozhodnutí a otevřené otázky.

Vybírej otázku, jejíž předpoklady už jsou známé. Polož ji přes dostupný nástroj
pro otázky, nabídni doporučení s důvodem a počkej na odpověď. Jedna otázka
nesmí skrývat několik nezávislých rozhodnutí. Schválené rozhodnutí znovu
neotevírej bez nového důkazu nebo změny požadavku.

Fakta z kódu a prostředí dohledávej přímo; nechtěj je od uživatele.
Subagenta použij pouze pro ohraničenou nezávislou rešerši, která vyžaduje
samostatný kontext. Nedeleguj jednotlivé lookupy ani jeden souvislý průchod
kódem. Na nezjištěném faktu nestav další rozhodnutí.

Zaměř se na rozsah, chybové stavy, měřitelné cíle a nákladné předpoklady.
Používej konkrétní scénáře místo požadavku na vyčerpávající hypotetické větvení.

Hotovo: uživatel potvrdil společné porozumění, podstatné větve jsou vyřešené
a zbývající nejistoty jsou výslovně označené. Implementaci nezačínej bez zadání.
