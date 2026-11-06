---
name: to-spec
description: "Převeď dohodnutý návrh z konverzace na ověřitelnou spec a publikuj ji do issue trackeru."
disable-model-invocation: true
---

# Spec z dohodnutého návrhu

Použij dosavadní konverzaci, doménovou dokumentaci a ověřené podklady.
Neopakuj hotový průzkum ani interview. Dohledej pouze chybějící nebo změněná
fakta. Rozpor se schváleným rozhodnutím předlož uživateli, nevyřeš ho domněnkou.

1. Načti pravidla issue trackeru a triage z `AGENTS.md`.
2. Urči seams (místa ověření) a kritéria úspěchu. Využij už schválená seams;
   nová nebo změněná nech potvrdit uživatelem.
3. Sepiš spec podle šablony níže. Každé požadované chování popiš jednou.
   Počet user stories určuje rozsah, nikoli délkový cíl.
4. Publikuj spec do issue trackeru. `ready-for-agent` použij jen tehdy, když
   nezůstává rozhodnutí blokující implementaci; jinak použij odpovídající
   triage stav a otevřenou otázku výslovně uveď.

## Šablona

- **Problém:** potřeba uživatele a pozorovatelné současné omezení.
- **Řešení:** požadované chování z pohledu uživatele.
- **User stories a akceptační kritéria:** úplný, neopakující se seznam;
  pro každé chování ověřitelný výsledek, včetně podstatných chybových stavů.
- **Přijatá rozhodnutí:** rozhraní, kontrakty, omezení a odkazy na ADR.
  Návrhy a neověřená tvrzení označ odděleně.
- **Ověření:** dohodnutá seams, existující vzory testů a měřitelné limity.
- **Mimo rozsah:** výslovně vyloučené chování.
- **Otevřené otázky:** zbývající rozhodnutí, nebo „Žádné“.

Spec nezahlcuj seznamem souborů ani implementačními kroky. Přesný kontrakt nebo
rozhodnutí z prototypu může mít krátký výřez kódu, pokud je přesnější než próza.

Hotovo: publikovaná spec rozlišuje rozhodnutí od návrhů a její kritéria lze
ověřit bez čtení celé konverzace. Implementaci ani `/to-tickets` nespouštěj.
