# Přibalené runtime závislosti

Release obsahuje zdrojové soubory, sestavené knihovny, licence a původní balíček `powershell-yaml`. Nástroje načítají modul z tohoto adresáře, nikoli z PSGallery ani z globálního `PSModulePath`.

| Závislost | Zdroj | Licence |
|---|---|---|
| `powershell-yaml` 0.4.12 | [PSGallery](https://www.powershellgallery.com/packages/powershell-yaml/0.4.12), [upstream commit](https://github.com/cloudbase/powershell-yaml/tree/aceb20d8162023243e0825d49923c2550c6cff5d) | Apache-2.0, soubor `powershell-yaml/0.4.12/LICENSE` |
| YamlDotNet, přibalený v modulu | `lib/net47/` a `lib/netstandard2.1/` v původním balíčku | MIT, soubory `lib/*/LICENSE.txt` |

SHA256 původního balíčku 0.4.12: `d4602bc7a4a093766520422d53ca8b09acde162286fae11e2ee6c8edfea07810`. Hash byl ověřen stažením balíčku 27. 10. 2026. Hash v `tools/requirements.psd1` tvoří pin pro další běhy, nikoli důkaz důvěryhodnosti prvního stažení.

Převzaté soubory zůstávají beze změny. Extrakce vynechává jen transportní metadata NuGet. Původní `.nupkg` zůstává v `packages/`. Před importem nástroje ověří hash balíčku a shodu všech souborů modulu s jeho obsahem. CI nekontroluje styl převzatého kódu; ověřuje jeho integritu. `git archive` zahrne tyto soubory do ZIPu releasu a attestace releasu pokryje celý ZIP.

Pokud proces již načetl stejnou přibalenou knihovnu z jiné kopie releasu, může použít tuto kopii. Nejdřív ověří požadovaný modul i již načtený modul proti aktuálnímu balíčku. Ve Windows tak nezamkne DLL v dočasné kopii. Nejde o import globálně instalovaného modulu.

## Aktualizace

Správce musí nejdřív zkontrolovat změny upstreamu, licence a SHA256 nového balíčku. Hash musí dodat explicitně; aktualizační skript nesmí sám schválit právě stažený obsah.

```powershell
.\tools\Update-VendoredModule.ps1 -Version <verze> -Sha256 <schválený-SHA256>
```

Skript ověří archiv, verzi a licence, připraví novou složku a původní balíček a teprve potom atomicky přepne pin v `requirements.psd1`. Přerušení před přepnutím zachová původní aktivní verzi. Opakovaný běh ověří již připravenou složku. Správce musí v PR aktualizovat tento záznam, odstranit neaktivní verze a spustit `.\tools\Invoke-LocalCi.ps1`. Skript necommitne změny a neotevře PR.

## Vývojové moduly a binárky CI

`Install-ToolDependencies.ps1 -Development` nejdřív ověří SHA256 `.nupkg` podle `requirements.psd1`. Pak zavolá `Save-Module` do dočasné složky a porovná uložené soubory s ověřeným archivem. Dvojí stažení brání tomu, aby druhá odpověď PSGallery nahradila ověřený obsah. Do `tools/.dependencies/` se zveřejní jen shodný modul. Každý import tuto shodu znovu ověří. Neshoda ukončí běh; oprava vyžaduje odstranit konkrétní poškozenou verzi v cache a instalaci zopakovat.

Bootstrap, acceptance a převod releasu pro vendoring vynechávají všechny cesty se segmentem `.dependencies`. Platí to i pro staging po přerušení instalace nebo aktualizace. Adresář `tools/vendor` tyto kontroly nevynechávají.

| Nástroj CI | Ověřené chování pinované akce | Kontrola platformy |
|---|---|---|
| Terraform 1.16.5 | [`setup-terraform`](https://github.com/hashicorp/setup-terraform/blob/b9cd54a3c349d3f38e8881555d616ced269862dd/lib/setup-terraform.js) archiv neověřuje | Před prvním spuštěním ověří `Test-ToolBinary.ps1` SHA256 skutečné binárky Linux amd64. Pin vznikl z archivu ověřeného proti [oficiálním SHA256SUMS](https://releases.hashicorp.com/terraform/1.16.5/terraform_1.16.5_SHA256SUMS). Wrapper zůstává vypnutý. |
| TFLint 0.60.0 | [`setup-tflint`](https://github.com/terraform-linters/setup-tflint/blob/6ffdbaa3be476b3431f7275c26966ef32ff60337/src/setup-tflint.js) kontroluje volitelný hash jen při stažení; cache může kontrolu obejít před spuštěním `--version` | `Install-CiBinary.ps1` místo akce ověří archiv proti pinu z [checksums.txt](https://github.com/terraform-linters/tflint/releases/download/v0.60.0/checksums.txt) před extrakcí. |
| Trivy 0.72.0 | [`setup-trivy`](https://github.com/aquasecurity/setup-trivy/blob/81e514348e19b6112ce2a7e3ecbafe19c1e1f567/action.yaml) spouští [pinovaný instalátor](https://github.com/aquasecurity/trivy/blob/75c4dc0f45c5d7ffd05ae26df1e0c666787bdf2a/contrib/install.sh), který ověřuje SHA256 archivu proti checksumům releasu | Cache zůstává vypnutá. |

Binární piny platí pro GitHub-hosted runner Linux amd64. Lokální CI neinstaluje binárky; vyžaduje lokální verze podle CI. Při změně verze Terraformu nebo TFLintu musí PR aktualizovat také odpovídající hash.

Kontrakty stahování: [Save-Module, PowerShellGet 2.x](https://learn.microsoft.com/powershell/module/powershellget/save-module?view=powershellget-2.x), [ruční stažení balíčku z PSGallery, API v2](https://learn.microsoft.com/powershell/gallery/how-to/working-with-packages/manual-download), [formát balíčku NuGet](https://learn.microsoft.com/nuget/reference/nuspec). Tyto operace vracejí soubor nebo ukládají soubory; nepřidávají volání GitHub REST API.
