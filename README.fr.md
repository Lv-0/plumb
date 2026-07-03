<div align="center">

<img src="assets/AppIcon-base.png" width="140" height="140" alt="Plumb">

# Plumb

Une ligne descend et trouve son point.

> Rendez votre Mac plus élément à utiliser.

Centre et place automatiquement en mosaïque les apps macOS — un bonheur pour les maniaques de l'ordre !

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg?style=flat-square)](#configuration-requise)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138.svg?style=flat-square)](https://swift.org)
[![Release](https://img.shields.io/badge/release-v2.0.48-success.svg?style=flat-square)](#téléchargement-et-installation)

[English](./README.md) · [简体中文](./README.zh.md) · [Español](./README.es.md) · **Français** · [日本語](./README.ja.md)

</div>

---

## 📖 Table des matières

- [À propos](#à-propos)
- [✨ Fonctionnalités](#-fonctionnalités)
- [📐 Mosaïque automatique](#-mosaïque-automatique)
- [📸 Captures d'écran](#-captures-décran)
- [Téléchargement et installation](#téléchargement-et-installation)
- [Utilisation](#utilisation)
- [Permissions](#permissions)
- [Configuration requise](#configuration-requise)
- [Compiler localement](#compiler-localement)
- [Empaqueter et publier](#empaqueter-et-publier)
- [FAQ](#faq)
- [Licence](#licence)

## À propos

`Plumb` est un **gestionnaire de fenêtres dans la barre de menus de macOS** qui prend en charge à la fois le centrage automatique et la mosaïque automatique par application.

Nommé d'après le **fil à plomb** (plumb line) — le poids que le charpentier laisse tomber pour trouver la vraie verticale, le vrai centre. C'est exactement ce que fait Plumb : placer doucement une fenêtre au vrai centre de l'écran ou à une position désignée.

- 🪧 Réside dans la barre de menus — aucune icône dans le Dock, zéro intrusion
- 🎯 Centre une fois au lancement, puis uniquement lorsqu'une fenêtre est rouverte / une nouvelle fenêtre est mise au premier plan
- 🖥️ Calcule dans la zone utile de l'écran (exclut automatiquement le Dock et la barre de menus), stable en multi-écrans
- 📐 Mosaïque automatique par app (liste autorisée) avec une marge de bord uniforme configurable
- 🪟 Interface de réglages Liquid Glass (macOS 26) — verre dépoli, recherche d'apps, interrupteurs en pilule

## ✨ Fonctionnalités

| Fonctionnalité | Description |
| --- | --- |
| 🎯 Centrer une fois | Centre une fois au lancement ; ensuite uniquement lorsqu'une fenêtre est rouverte / une nouvelle fenêtre est mise au premier plan |
| ✋ Ne lutte pas avec votre disposition | Glisser une fenêtre ne redéclenche jamais le centrage |
| 🖥️ Évite précisément le Dock/barre de menus | Basé sur `screen.frame - screen.visibleFrame`, stable en multi-écrans |
| 📐 Mosaïque automatique par app | Mécanisme de liste autorisée avec une marge uniforme configurable (px) |
| 🎚️ Marge de mosaïque par app | Touchez une app en mosaïque pour définir une marge personnalisée uniquement pour elle ; les apps sans réglage utilisent la marge globale par défaut |
| 🔄 Rafraîchissement en direct de la liste d'apps | Les apps nouvellement installées apparaissent immédiatement dans le sélecteur, sans redémarrage |
| 🪟 Interface Liquid Glass | Verre dépoli macOS 26, recherche, interrupteurs en pilule |
| 🧠 Détection intelligente d'espace de coordonnées | Détecte automatiquement l'espace de coordonnées de chaque app et le met en cache pour la stabilité |
| 🪧 Présence non intrusive dans la barre de menus | Icône uniquement dans la barre de menus, n'occupe pas le Dock |

## 📐 Mosaïque automatique

Ouvrez `Réglages de mosaïque…` depuis la barre de menus pour activer/désactiver la fonction et gérer votre flux de travail.

- Configurez une seule marge de bord uniforme (px)
- **Marge de mosaïque par app** : touchez une app dans la liste de mosaïque pour déployer un tiroir de marge intégré et définir une marge personnalisée uniquement pour cette app ; les apps sans réglage personnalisé continuent d'utiliser la marge globale par défaut. Un bouton « Par défaut » réinitialise une app à la valeur globale.
- Sélectionnez les apps autorisées parmi les applications installées (les apps système sont masquées par défaut, commutable)
- Pour les apps autorisées, **la mosaïque a la priorité** sur le centrage automatique
- Le déclenchement se fait une fois par démarrage de processus (PID) ; aucune mosaïque répétée dans le même processus
- Si une fenêtre ne peut pas être redimensionnée, elle est ignorée
- Les apps de documents (Pages, Numbers, Word, Excel) ignorent automatiquement le sélecteur de modèles/fichiers ; seul le document ouvert est placé en mosaïque

> La sémantique s'inspire des concepts de configuration d'Amethyst :
> - `window-margin-size` : équivalent à la marge de mosaïque de ce projet
> - `floating + floating-is-blacklist=false` : équivalent à la mosaïque automatique par liste autorisée ici

## 📸 Captures d'écran

<table>
  <tr>
    <td width="50%" align="center"><b>Centrer — liste d'autorisation</b></td>
    <td width="50%" align="center"><b>Mosaïque — tiroir de marge par app</b></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="assets/Centering.png" alt="Onglet Centrer"></td>
    <td width="50%" align="center"><img src="assets/Tiling.png" alt="Onglet Mosaïque avec tiroir de marge par app"></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><b>Autorisations — Accessibilité, Enregistrement d'écran, Lancement à la connexion</b></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><img src="assets/Permissions.png" alt="Onglet Autorisations"></td>
  </tr>
</table>

## Téléchargement et installation

### Option 1 : Télécharger le DMG (recommandé)

1. Téléchargez la dernière version de `Plumb.dmg` depuis [Releases](../../releases).
2. Ouvrez le DMG et glissez `Plumb.app` dans `Applications`.
3. Dans `Applications`, faites un clic droit sur `Plumb.app` → `Ouvrir` → cliquez à nouveau sur `Ouvrir`.
4. Si bloqué, allez dans `Réglages Système → Confidentialité et sécurité` et cliquez sur « Ouvrir quand même ».

### Option 2 : Compiler depuis le code source

```bash
swift build -c release
./.build/release/Plumb
```

Voir [Compiler localement](#compiler-localement).

## Utilisation

1. Après le lancement, une icône de goutte d'eau apparaît dans la barre de menus.
2. Accordez la permission d'[Accessibilité](#accessibilité) — le centrage en dépend.
3. (Facultatif) Accordez la permission d'[Enregistrement d'écran](#enregistrement-décran) pour améliorer la stabilité de la détection des coordonnées en multi-écrans.
4. Cliquez sur l'icône de la barre de menus :
   - Déclenchez le centrage manuellement
   - Ouvrez `Réglages de mosaïque…` pour configurer la liste autorisée et la marge

> 💡 **Principe de conception** : chaque fenêtre est centrée/mosaïque **une seule fois** (clé `pid:windowNumber`). Glisser manuellement une fenêtre n'est jamais « corrigé » — Plumb ne lutte pas avec votre disposition manuelle.

## Permissions

### Accessibilité

- **Chemin** : `Réglages Système → Confidentialité et sécurité → Accessibilité`
- **Pourquoi requis** : L'app utilise les APIs d'accessibilité de macOS pour lire le cadre de la fenêtre au premier plan et écrire une nouvelle position pour le centrage.
- **Sans elle** : L'app ne peut pas lire la géométrie des fenêtres ni les déplacer, le centrage ne fonctionnera donc pas.

### Enregistrement d'écran

- **Chemin** : `Réglages Système → Confidentialité et sécurité → Enregistrement d'écran`
- **Pourquoi requis** : L'app a besoin du contexte complet de l'écran pour calculer de façon fiable les limites d'affichage utilisables et éviter le Dock/la barre de menus lors du centrage.
- **Sans elle** : Le centrage dépendant du contexte d'écran peut devenir instable en multi-écrans ou dans des dispositions complexes.

### Limite des permissions

- ❌ L'app **ne téléverse pas le contenu de l'écran** et **ne collecte aucune télémétrie**.
- ✅ Les permissions sont utilisées **uniquement** pour les calculs locaux de géométrie et de positionnement des fenêtres.

## Configuration requise

- **macOS 26+** (compilé avec le SDK macOS 26 et l'interface Liquid Glass ; les versions antérieures ne sont pas prises en charge)
- Xcode Command Line Tools (`xcode-select --install`)

## Compiler localement

```bash
# Lancer les tests
swift test

# Compiler un binaire Release
swift build -c release

# Lancer directement
./.build/release/Plumb
```

## Empaqueter et publier

### Empaqueter en .app et .dmg

```bash
scripts/build_app.sh      # produit dist/Plumb.app
scripts/create_dmg.sh     # produit dist/Plumb.dmg
```

Le DMG contient :

- `Plumb.app`
- `Applications` (raccourci vers le dossier Applications du système)

> Installez en glissant `Plumb.app` dans `Applications`.

### Signer et notariser (Developer ID)

```bash
export DEVELOPER_ID_APP="Developer ID Application: YOUR_NAME (TEAMID)"
export NOTARY_PROFILE="AC_NOTARY"
scripts/sign_and_notarize.sh
```

### Flux de publication en une étape (pour GitHub Releases)

```bash
export DEVELOPER_ID_APP="Developer ID Application: YOUR_NAME (TEAMID)"
export NOTARY_PROFILE="AC_NOTARY"
scripts/release_build.sh              # compiler + empaqueter + signer/notariser + vérifier

GITHUB_TOKEN=... scripts/publish_release.sh v1.0.0   # publier sur GitHub Releases
```

> ⚠️ Les DMG non signés/non notarisés peuvent être bloqués par Gatekeeper sur un nouveau Mac et apparaître comme « endommagés ».

## FAQ

<details>
<summary><b>Avertissement « endommagé » ou « développeur non identifié » à l'ouverture de Plumb.app ?</b></summary>

C'est le flux normal de Gatekeeper pour les distributions non notarisées — **ce n'est pas** une corruption du code de l'app. Exécutez :

```bash
xattr -dr com.apple.quarantine /Applications/Plumb.app
```

Ou allez dans `Réglages Système → Confidentialité et sécurité` et cliquez sur « Ouvrir quand même » en bas.

</details>

<details>
<summary><b>Le centrage ne fonctionne pas ?</b></summary>

Assurez-vous que la permission d'**Accessibilité** est accordée : `Réglages Système → Confidentialité et sécurité → Accessibilité`, et que Plumb est activé. Vous devrez peut-être redémarrer Plumb après l'octroi.

</details>

<details>
<summary><b>Le centrage est imprécis sur une configuration multi-écrans ?</b></summary>

Accordez la permission d'**Enregistrement d'écran**. Plumb utilise l'API `CGWindowList` comme signal secondaire pour identifier plus précisément l'écran et l'espace de coordonnées de la fenêtre.

</details>

<details>
<summary><b>J'ai glissé une fenêtre et elle a été recentrée ?</b></summary>

Non. Plumb centre/place en mosaïque chaque fenêtre **une seule fois** — les glissés manuels ne sont jamais « corrigés ».

</details>

## Licence

Ce projet est open source sous la [Licence MIT](./LICENSE).

---

<div align="center">

[English](./README.md) · [简体中文](./README.zh.md) · [Español](./README.es.md) · **Français** · [日本語](./README.ja.md)

Si Plumb vous est utile, un ⭐ Star est apprécié.

</div>
