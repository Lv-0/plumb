<div align="center">

<img src="assets/AppIcon-base.png" width="140" height="140" alt="Plumb">

# Plumb

Una línea desciende y encuentra su punto.

> Haz que tu Mac se sienta más elegante de usar.

Centra y coloca en mosaico las apps de macOS automáticamente — ¡una bendición para los amantes del orden!

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg?style=flat-square)](#requisitos)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138.svg?style=flat-square)](https://swift.org)
[![Release](https://img.shields.io/badge/release-v2.0.60-success.svg?style=flat-square)](#descarga-e-instalación)

[English](./README.md) · [简体中文](./README.zh.md) · **Español** · [Français](./README.fr.md) · [日本語](./README.ja.md)

</div>

---

## 📖 Índice

- [Acerca de](#acerca-de)
- [✨ Funciones](#-funciones)
- [📐 Mosaico automático](#-mosaico-automático)
- [📸 Capturas](#-capturas)
- [Descarga e instalación](#descarga-e-instalación)
- [Uso](#uso)
- [Permisos](#permisos)
- [Requisitos](#requisitos)
- [Compilar localmente](#compilar-localmente)
- [Empaquetar y publicar](#empaquetar-y-publicar)
- [Preguntas frecuentes](#preguntas-frecuentes)
- [Licencia](#licencia)

## Acerca de

`Plumb` es un **gestor de ventanas en la barra de menús de macOS** que soporta tanto el centrado automático como el mosaico automático por aplicación.

Recibe el nombre de la **plomada** (plumb line) — el peso que el carpintero deja caer para encontrar la verdadera vertical, el verdadero centro. Eso es justo lo que hace Plumb: colocar suavemente una ventana en el centro exacto de la pantalla o en una posición designada.

- 🪧 Vive en la barra de menús — sin icono en el Dock, cero intrusiones
- 🎯 Evalúa la disposición en cada activación de la app o cambio de Space y, después, evita el trabajo duplicado dentro de ese ciclo
- 🖥️ Calcula dentro del área útil de la pantalla (excluye automáticamente el Dock y la barra de menús), estable en configuraciones multi-pantalla
- 📐 Mosaico automático por aplicación (lista de permitidas) con un margen global y márgenes direccionales opcionales por app
- 🪟 Interfaz de ajustes Liquid Glass (macOS 26) — vidrio esmerilado, búsqueda de apps, interruptores en píldora

## ✨ Funciones

| Función | Descripción |
| --- | --- |
| 🎯 Disposición por activación | Vuelve a evaluarla al activar una app o cambiar de Space y evita el trabajo duplicado durante el ciclo actual |
| ✋ Respeta la disposición manual | Un movimiento o cambio de tamaño real deja esa ventana intacta durante el resto del ciclo actual de activación/Space |
| 🖥️ Evita con precisión el Dock/barra de menús | Basado en `screen.frame - screen.visibleFrame`, estable en multi-pantalla |
| 📐 Mosaico automático por app | Mecanismo de lista de permitidas con margen global configurable (px) |
| 🎚️ Márgenes de mosaico por app | Haz clic en cualquier app en mosaico para configurar por separado sus márgenes superior, inferior, izquierdo y derecho; las apps sin ajuste usan el valor global predeterminado |
| 🔄 Refresco en vivo de la lista de apps | Las apps recién instaladas aparecen en el selector de ajustes de inmediato, sin reiniciar |
| 🪟 Interfaz Liquid Glass | Vidrio esmerilado de macOS 26, búsqueda, interruptores en píldora |
| 🧠 Detección inteligente de coordenadas | Detecta automáticamente el espacio de coordenadas de cada app y lo cachea para estabilidad |
| 🪧 Presencia no intrusiva en la barra de menús | Solo icono en la barra de menús, no ocupa el Dock |

## 📐 Mosaico automático

Abre `Ajustes de mosaico…` desde la barra de menús para activar/desactivar la función y gestionar tu flujo de trabajo.

- Configura un único margen uniforme (px)
- **Ajuste de márgenes por app**: haz clic en cualquier app de la lista de mosaico para desplegar un panel integrado y configurar de forma independiente sus márgenes superior, inferior, izquierdo y derecho. Las apps sin ajuste usan el margen global en los cuatro lados; «Usar predeterminado» elimina el ajuste.
- Selecciona las apps permitidas entre las aplicaciones instaladas (las apps del sistema se ocultan por defecto, conmutable)
- Para las apps permitidas, **el mosaico tiene prioridad** sobre el centrado automático
- El ámbito de disparo es un ciclo de activación de la app o de Space, no toda la vida del proceso. Al reactivar una app o cambiar de Space comienza una nueva evaluación.
- Plumb prueba tanto la escritura de tamaño AX estándar como una alternativa mediante AXFrame. Reposicionar la ventana sin redimensionarla no se considera un mosaico correcto: se realizan reintentos limitados y solo se acepta la geometría con el ancho objetivo o la alternativa documentada con anclaje vertical.
- En las apps de documentos (Pages, Numbers, Word, Excel), las galerías de plantillas y las listas de archivos solo se centran. Los documentos guardados se colocan en mosaico; cuando se detecta un documento sin guardar, Plumb espera brevemente a que su marco se estabilice antes de colocarlo en mosaico.

> La semántica está inspirada en los conceptos de configuración de Amethyst:
> - `window-margin-size`: equivalente al margen de mosaico de este proyecto
> - `floating + floating-is-blacklist=false`: equivalente al mosaico automático por lista de permitidas aquí

## 📸 Capturas

<table>
  <tr>
    <td width="50%" align="center"><b>Centrar — lista de apps permitidas</b></td>
    <td width="50%" align="center"><b>Mosaico — cajón de margen por app</b></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="assets/Centering.png" alt="Pestaña Centrar"></td>
    <td width="50%" align="center"><img src="assets/Tiling.png" alt="Pestaña Mosaico con cajón de margen por app"></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><b>Permisos — Accesibilidad, Grabación de pantalla, Inicio al iniciar sesión</b></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><img src="assets/Permissions.png" alt="Pestaña Permisos"></td>
  </tr>
</table>

## Descarga e instalación

### Opción 1: Descargar el DMG (recomendado)

1. Descarga la última versión de `Plumb.dmg` desde [Releases](../../releases).
2. Abre el DMG y arrastra `Plumb.app` a `Applications`.
3. En `Applications`, haz clic derecho en `Plumb.app` → `Abrir` → vuelve a hacer clic en `Abrir`.
4. Si se bloquea, ve a `Ajustes del sistema → Privacidad y seguridad` y haz clic en "Abrir de todos modos".

### Opción 2: Compilar desde el código fuente

```bash
swift build -c release
./.build/release/Plumb
```

Consulta [Compilar localmente](#compilar-localmente).

## Uso

1. Tras el inicio, aparece el icono de Plumb en la barra de menús.
2. Concede el permiso de [Accesibilidad](#accesibilidad) — el centrado depende de él.
3. (Opcional) Concede el permiso de [Grabación de pantalla](#grabación-de-pantalla) para mejorar la estabilidad de la detección de coordenadas en multi-pantalla.
4. Haz clic en el icono de la barra de menús:
   - Dispara el centrado manualmente
   - Abre `Ajustes de mosaico…` para configurar la lista de permitidas, el margen global y los márgenes direccionales por app

> 💡 **Principio de diseño**: la disposición automática se limita al ciclo actual de activación de la app o de Space. Un movimiento o cambio de tamaño manual real se respeta durante el resto de ese ciclo; al reactivar la app o cambiar de Space se elimina la marca manual y se vuelve a evaluar la disposición.

## Permisos

### Accesibilidad

- **Ruta**: `Ajustes del sistema → Privacidad y seguridad → Accesibilidad`
- **Por qué es necesario**: La app usa las APIs de accesibilidad de macOS para leer el marco de la ventana frontal y escribir una nueva posición para centrarla.
- **Sin él**: La app no puede leer la geometría de la ventana ni mover ventanas, por lo que el centrado no funcionará.

### Grabación de pantalla

- **Ruta**: `Ajustes del sistema → Privacidad y seguridad → Grabación de pantalla`
- **Por qué es necesario**: La app necesita el contexto completo de la pantalla para calcular de forma fiable los límites de visualización utilizables y evitar el Dock/barra de menús al centrar.
- **Sin él**: El centrado dependiente del contexto de pantalla puede volverse inestable en multi-pantalla o disposiciones complejas.

### Límite de permisos

- ❌ La app **no sube contenido de la pantalla** y **no realiza recolección de telemetría**.
- ✅ Los permisos se usan **solo** para cálculos locales de geometría de ventanas y posicionamiento.

## Requisitos

- **macOS 26+** (compilado con el SDK de macOS 26 y la interfaz Liquid Glass; las versiones anteriores no son compatibles)
- Xcode Command Line Tools (`xcode-select --install`)

## Compilar localmente

```bash
# Ejecutar pruebas
swift test

# Compilar un binario Release
swift build -c release

# Ejecutar directamente
./.build/release/Plumb
```

## Empaquetar y publicar

### Publicación con un solo comando (recomendado)

`scripts/release.sh` ejecuta todo el flujo de extremo a extremo — subir versión, compilar, firmar, empaquetar, etiquetar, empujar, publicar el Release de GitHub y actualizar el appcast OTA:

```bash
# Escribe primero las notas OTA en 5 idiomas (en/zh/es/fr/ja, una línea cada una)
scripts/release.sh --print-notes-template > /tmp/notes.txt
$EDITOR /tmp/notes.txt

# Luego publica (firmado localmente por defecto)
bash scripts/release.sh 2.0.50 --notes-file /tmp/notes.txt
```

Qué hace, en orden: comprobaciones previas (árbol limpio, tests, build de release, escaneo de secretos) → subir 5 badges README → compilar `.app` firmado + DMG + zip OTA → verificar codesign (y afirmar que el designated requirement es un hash de hoja de certificado, para que los permisos TCC sobrevivan a las actualizaciones) → etiquetar + empujar → crear el Release de GitHub con los assets → actualizar `appcast.json` (version/url/sha + notas en 5 idiomas). Detalles completos y notas de seguridad en [RELEASING.md](./RELEASING.md).

### Compilar artefactos individualmente

```bash
scripts/build_app.sh      # produce dist/Plumb.app (firmado con Plumb Local Signer)
scripts/create_dmg.sh     # produce dist/Plumb.dmg
scripts/create_zip.sh     # produce dist/Plumb-<version>.zip (para OTA)
```

El DMG incluye `Plumb.app` y un atajo a `Applications` — instala arrastrando.

### Modos de firma

| Modo | Cuándo | Cómo |
| --- | --- | --- |
| **Firma local** (predeterminado) | Builds diarios, pruebas | `scripts/build_app.sh` usa `Plumb Local Signer` automáticamente (ejecuta `scripts/make_signing_cert.sh` una vez primero) |
| **Developer ID + notarizado** | Distribución pública sin avisos de Gatekeeper | `scripts/release.sh --sign developer-id` (requiere las variables de entorno `DEVELOPER_ID_APP` + `NOTARY_PROFILE`), o el independiente `scripts/sign_and_notarize.sh` |

> ⚠️ Los DMG firmados localmente/no notarizados pueden ser bloqueados por Gatekeeper en un Mac nuevo y aparecer como "dañados" — ejecuta `xattr -dr com.apple.quarantine /Applications/Plumb.app` (ver [Preguntas frecuentes](#preguntas-frecuentes)).

## Preguntas frecuentes

<details>
<summary><b>¿Aviso de "dañado" o "desarrollador no identificado" al abrir Plumb.app?</b></summary>

Este es el flujo normal de Gatekeeper para distribuciones no notarizadas — **no** es una corrupción del código de la app. Ejecuta:

```bash
xattr -dr com.apple.quarantine /Applications/Plumb.app
```

O ve a `Ajustes del sistema → Privacidad y seguridad` y haz clic en "Abrir de todos modos" al final.

</details>

<details>
<summary><b>¿El centrado no funciona?</b></summary>

Asegúrate de haber concedido el permiso de **Accesibilidad**: `Ajustes del sistema → Privacidad y seguridad → Accesibilidad`, y de que Plumb esté activado. Puede que necesites reiniciar Plumb tras concederlo.

</details>

<details>
<summary><b>¿El centrado de ventanas es impreciso en una configuración multi-pantalla?</b></summary>

Concede el permiso de **Grabación de pantalla**. Plumb usa la API `CGWindowList` como señal secundaria para identificar con mayor precisión la pantalla y el espacio de coordenadas de la ventana.

</details>

<details>
<summary><b>Arrastré una ventana y se volvió a centrar, ¿no?</b></summary>

Durante el ciclo actual de activación de la app o de Space, un movimiento o cambio de tamaño real debe dejar la ventana donde la colocaste. Al reactivar la app o cambiar de Space comienza un nuevo ciclo de disposición, por lo que Plumb puede volver a centrarla o colocarla en mosaico.

</details>

## Licencia

Este proyecto es de código abierto bajo la [Licencia MIT](./LICENSE).

---

<div align="center">

[English](./README.md) · [简体中文](./README.zh.md) · **Español** · [Français](./README.fr.md) · [日本語](./README.ja.md)

Si Plumb te ayuda, se agradece un ⭐ Star.

</div>
