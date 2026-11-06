---
name: domain-modeling
description: "Zpřesňuj doménové pojmy a zapisuj přijatá rozhodnutí do kontextu a ADR."
---

# Doménový model

Řiď se [doménovou dokumentací](../../../docs/agents/domain.md).
Glosář tohoto repozitáře je v `CONTEXT.md`; při více kontextech použij
`CONTEXT-MAP.md`. Zachovej existující strukturu, nevytvářej druhý glosář.

Při návrhu porovnávej používané termíny s glosářem. Rozpor ověř v kódu
a předlož uživateli jako otázku; neschválený vlastní návrh nezapisuj
jako přijaté rozhodnutí. Nejasný termín zpřesni na konkrétních scénářích.

Nově dohodnutý pojem zapiš průběžně. Pro nový kontext použij
[formát kontextu](CONTEXT-FORMAT.md). Glosář popisuje doménu, ne implementační
plán nebo průběžné poznámky.

ADR nabídni, pokud je rozhodnutí nákladné změnit, bez kontextu překvapivé
a vzniklo skutečným porovnáním variant. Použij [formát ADR](ADR-FORMAT.md).
Při změně přijatého rozhodnutí zachovej historii a výslovně uveď nový stav,
zdroj rozhodnutí a náhradu. Pouhá preference agenta není souhlas ke změně ADR.

Hotovo: zapsané pojmy a rozhodnutí odpovídají potvrzení uživatele a jejich
stav je jednoznačný. Rešerši ani implementaci automaticky nedeleguj.
