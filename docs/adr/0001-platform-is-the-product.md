# Platforma je produkt, workshop ji předvádí

Platforma je produkt pro kteréhokoli zákazníka s GHE.com a EMU. Platforma se skládá z modulů. Modul je schopnost s deklarovanými předpoklady. Zákazník nasadí vybrané moduly a jejich předpoklady, nebo všechny moduly v pořadí závislostí. Instance jde nasadit a odstranit jako celek.

Workshop je samostatný konzument, který platformu předvádí. Workshop vzniká až po platformě a jeho potřeby neurčují návrh platformy.

## Considered Options

- Modul podle kapitoly workshopu. Zamítnuto: Více kapitol používá stejnou schopnost (rulesety, ACR), takže kód by se zdvojil nebo by se skryla závislost.
- Modul podle vrstvy (GitHub, Azure, stanice). Zamítnuto: Zákazník nevybírá vrstvy, ale schopnosti.
