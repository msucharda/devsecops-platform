---
name: grill-with-docs
description: "Vyjasni návrh s uživatelem a průběžně zaznamenej dohodnuté pojmy a rozhodnutí."
disable-model-invocation: true
---

# Návrh s dokumentací

Vyvolej skills `grilling` a `domain-modeling`. Návrh vlastní aktuální session.
Respektuj doménovou dokumentaci z `AGENTS.md`; v tomto repozitáři je glosář
součástí `CONTEXT.md`.

Fakta ověřuj přímo. Samostatnou rešerši deleguj jen tehdy, když má ohraničenou
nezávislou otázku a vyžaduje samostatný kontext. Stejnou rešerši neopakuj
souběžně. Uživatel rozhoduje; návrhy agenta drž oddělené od přijatých rozhodnutí.

Průběžně zapisuj přijatá rozhodnutí a důvody do vhodné doménové dokumentace.
ADR vytvářej podle kritérií `domain-modeling`, ne pro každou odpověď.

Hotovo: uživatel potvrdil rozsah, hranice, podstatná rozhodnutí a zbývající
nejistoty. `/to-spec` a `/to-tickets` může potom zavolat ve stejné session.
Tyto uživatelské příkazy nespouštěj automaticky.
