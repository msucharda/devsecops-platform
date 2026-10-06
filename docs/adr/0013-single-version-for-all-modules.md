# Platforma má jednu verzi pro všechny moduly

Release platformy má jednu verzi SemVer pro všechny moduly. Moduly sdílejí schéma konfigurace instance a závislé moduly čtou výstupy předpokladů. Jedna verze proto zaručuje, že zákazník nasadí jen kombinaci modulů, kterou autor otestoval na referenční instanci.

## Considered Options

- Verze pro každý modul. Zamítnuto: Zákazník by mohl kombinovat verze modulů, které spolu nikdo netestoval, a autor by udržoval matici kompatibility.

## Consequences

- Major verze označuje breaking change ve schématu konfigurace instance nebo ve výstupech modulu, případně odebraný modul.
- Zákazník smí upgradovat jen o jednu major verzi najednou. Release notes major verze popisují migraci.
- Oprava jednoho modulu vyžaduje release celé platformy.
