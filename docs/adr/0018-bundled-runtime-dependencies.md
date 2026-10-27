# Runtime závislosti patří do releasu

Instance nesmí za běhu stahovat PowerShell moduly z PSGallery. Release obsahuje runtime závislosti včetně licencí a původních balíčků; před importem nástroje ověří jejich SHA256 a shodu souborů. Rozhodnutí schválil uživatel v #123 dne 27. 10. 2026: odstraňuje závislost deploye na dostupnosti PSGallery a zahrnuje převzatý kód do attestace releasu.

Vývojové moduly zůstávají mimo release. Instalátor je stáhne do izolované cache, ověří hash podle pinu a porovná výstup `Save-Module` s ověřeným archivem před importem. Stažené binárky CI musí projít kontrolou SHA256 před prvním spuštěním. Aktualizaci verze a hashe musí schválit review; samotný hash z prvního stažení neprokazuje důvěryhodný původ. Nahrazení YAML parseru vlastní implementací by odstranilo jednu knihovnu, ale přeneslo by údržbu formátu YAML do platformy.
