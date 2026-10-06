# Verze 1 podporuje jen konektivitu hub-and-spoke

Modul `slz-connectivity` nasazuje hub VNet s Azure Firewall. SKU firewallu je parametr konfigurace instance. Každá podporovaná topologie vyžaduje samostatné testování modulů, které se k hubu připojují. Hub VNet nemá na rozdíl od virtual hubu ve Virtual WAN vlastní hodinový poplatek, takže opakovaný teardown referenční instance je levnější.

## Considered Options

- Virtual WAN. Odloženo: Platforma ho může doplnit jako alternativní modul konektivity.
- Obě topologie jako parametr jednoho modulu. Zamítnuto: Zdvojí testování závislých modulů.

## Consequences

- Zákazník, který vyžaduje Virtual WAN, musí počkat na modul pro Virtual WAN.
