# Platforma podporuje jen SLZ a staví na Azure/alz a AVM

Platforma nasazuje jen Sovereign Landing Zone. Moduly landing zone používají provider `Azure/alz`, knihovnu `platform/slz` a pattern moduly AVM, stejně jako starter ALZ Terraform acceleratoru. Zákazníci platformy řeší suverenitu dat, proto podpora ALZ by zdvojila testování bez přínosu.

## Considered Options

- ALZ i SLZ jako parametr modulu. Zamítnuto: Zákazníci platformy řeší jen SLZ.
- Vlastní implementace landing zone. Zamítnuto: Implementace by se od CAF postupně odchýlila a Microsoft by ji neudržoval.
