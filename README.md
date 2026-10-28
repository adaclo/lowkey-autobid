# sbid-autofill

Rellena las **activitats diàries** y los **informes periòdics** pendientes de las prácticas (FCT / FP Dual) en [sBID](https://www.empresaiformacio.org/sBid), con el reparto de horas que tú elijas. Hay dos formas de usarlo, sin instalar nada en ninguna:

| | Para qué | Credenciales |
|---|---|---|
| [`sbid-autofill.js`](sbid-autofill.js) | Rellenar a mano, una vez, con un panel en el navegador | Ninguna: usa tu sesión abierta |
| [`windows/`](windows) | **Automático cada vez que enciendes el PC** (PowerShell, ya viene con Windows) | Las guardas en un fichero local |

> **Úsalo solo para registrar horas que de verdad has hecho.** Lo que se guarda lo ven tu tutor/a del centro y de la empresa, y es responsabilidad tuya. El proyecto no es oficial ni está afiliado a sBID/Empresa i Formació.

## Automático al encender el PC (Windows)

Al arrancar el PC entra en sBID con tu usuario, mira si hay días o informes pendientes y los rellena. Solo usa PowerShell: no hace falta Node ni instalar nada. Hace el login con peticiones directas, así que **guarda tus credenciales en un fichero local**.

1. Descarga o clona el repo en una carpeta tuya (mejor fuera de OneDrive).
2. Doble clic en **`0-configurar.bat`**: el **asistente**. Te pide usuario y contraseña, entra en sBID, **lee las actividades reales de tu plan** y te deja elegir con una lista de flechas cuáles rellenar y con qué peso (también horas por día, días a saltar, informes y valoración). Escribe `config.ps1` con la contraseña cifrada con tu cuenta de Windows, te ofrece una simulación y deja instalado el arranque automático. Se puede volver a ejecutar cuando cambie tu plan.
3. Alternativa manual: copia `config.example.ps1` como `config.ps1`, edítalo y usa **`1-probar.bat`** (comprueba el login y enseña qué rellenaría, sin guardar nada) y **`2-instalar.bat`** (arranque de Windows). Para quitarlo, `quitar.bat`.

En la lista del asistente: ↑/↓ te mueves, **Espacio** marca/desmarca, ←/→ cambian el peso (1-5), **A** marca todas, **N** ninguna, **Enter** continúa y **Esc** cancela.

Desde entonces, cada vez que enciendes el PC se abre una ventana con un **panel de colores**: espera 45 s a que haya red, entra en sBID y va mostrando en vivo qué hace (estado, contadores, barra de progreso y las últimas acciones). Al terminar se cierra sola a los 6 s; si algo falla o se para, se queda 60 s para que lo leas (cualquier tecla la cierra antes). El resultado también queda en `windows/sbid-daily.log`.

```
┌──────────────────────────────────────────────────────────────────┐
│  sBID autofill                                 28/10/2026 18:08  │
└──────────────────────────────────────────────────────────────────┘

  Estado      + Completado: 16 registrados
  Usuario     alumne
  Pendientes  30      Registrados 16    Simulados 0     Saltados 5

  ████████████████████████████████████████████  100%

  Actividad
   + Informe 2026-06-30 -> MOLT ADEQUADA
   - Salto 13/06/2026: fin de semana
   + Guardado 2026-06-15 -> 1.5:2h 2.4:1.5h 1.4:0.5h
```

`ver-panel.bat` enseña el panel con datos de mentira, sin entrar en sBID. Si prefieres que no abra ninguna ventana: `sbid-daily.ps1 -Install -Hidden` (en ese caso avisa con una notificación de Windows).

- `windows/config.ps1` está en `.gitignore`: **no lo subas nunca**. Con el asistente la contraseña se guarda cifrada (`PasswordProtected`, DPAPI: solo se descifra con tu cuenta de Windows en ese PC); si la pones a mano en `Password` queda en claro. También puedes usar las variables de entorno `SBID_USER` y `SBID_PASS`. Protege el PC (clave de Windows, disco cifrado).
- Por defecto rellena hasta ayer, y el día de hoy solo si el PC arranca después de `FillTodayAfter` (18:00). Salta fines de semana y `SkipDates`.
- Tope `MaxPerRun` (60) por ejecución: un atraso grande se reparte en varios arranques.
- Si el login falla **no reintenta** (para no bloquear tu cuenta); solo reintenta si no hay red.
- **Ojo:** no sabe si ese día fuiste a trabajar. Pon vacaciones, bajas y festivos en `SkipDates`, o dará horas igualmente.

Opciones del script: `-Check` (solo login y recuento), `-DryRun` (simula), `-Ui` (con panel), `-UiDemo` (panel de prueba), `-Install [-Hidden]` / `-Uninstall` (arranque de Windows). En `config.ps1` puedes ajustar `UiCloseSeconds` y `UiErrorCloseSeconds`.

## Rellenar a mano desde el navegador

1. Entra en <https://www.empresaiformacio.org/sBid> e inicia sesión como siempre.
2. Abre las herramientas de desarrollador (`F12`) → pestaña **Consola**.
3. Copia todo el contenido de [`sbid-autofill.js`](sbid-autofill.js) y pégalo. Chrome te pedirá escribir `allow pasting` la primera vez.
4. En el panel de arriba a la derecha pulsa **Leer actividades**, ajusta horas, bloque mínimo, actividades por día, semilla, fecha límite y valoración, y elige actividades y pesos (o **Marcar por palabras**, p. ej. `seguretat, base de dades`). Con **Simulación** activada (por defecto) solo muestra qué haría; quítala y pulsa **Ejecutar** para guardar de verdad.

## Qué hace exactamente

- Recorre la lista de **Pendents** de la Agenda de arriba abajo.
- **Días:** reparte las horas entre las actividades elegidas, en múltiplos de 15 min, sin pasar del máximo diario que indica sBID. Con la misma semilla sale el mismo reparto.
- **Informes periódicos:** pone en todas las tareas la valoración que elijas (por defecto, la más alta).
- Tras cada guardado comprueba que la tarea ha salido de pendientes; si no, **se detiene**.

## Cómo funciona por dentro

Hace las mismas peticiones que la web:

| Qué | Petición |
|---|---|
| Login | `POST /sBid/modules/Login` con `moduleaction=doLogin`, `username`, `password` |
| Lista de pendientes | `GET /sBid/modules/Agenda?moduleaction=show` |
| Formulario de un día | `GET /sBid/modules/ActivitatFct?moduleaction=show&codi_conveni=…&data=AAAAMMDD&hash_code=…` |
| Guardar un día | `POST /sBid/modules/ActivitatFct` con `moduleaction=save`, `horesConsignades=<total>` y un campo `inp_<id>=<horas>` por actividad |
| Guardar un informe | `POST /sBid/modules/ActivitatValoracioFct` con `moduleaction=save` y `inp_<id>=<código de valoración>` |

El `hash_code` lo genera el servidor y se lee del enlace de la Agenda; los `inp_<id>` se leen del propio formulario, así que no hay nada fijo de ningún alumno.

## Limitaciones

- No gestiona ausencias, festivos ni días de baja: esos días hay que marcarlos a mano (o ponerlos en `SkipDates`).
- Está escrito contra la versión actual de sBID (textos en catalán). Si cambian el HTML, puede dejar de funcionar.
- La Agenda solo enseña unos pocos pendientes a la vez; si los primeros son días que se saltan (fin de semana, fecha futura, `SkipDates`), el script se para y te avisa.

## Desarrollo

```bash
npm test
```

Node solo hace falta para desarrollar: prueba el reparto de horas y ejecuta `windows/sbid-daily.ps1` y el asistente `windows/setup.ps1` contra un sBID simulado (solo en Windows). Usarlo no requiere Node. Para probar el asistente a mano: `MOCK_ACTS=31 node dev/mock-sbid.js` (usuario `alumne`, contraseña `secret`) y `setup.ps1 -BaseUrl http://127.0.0.1:8765 -ConfigPath .\demo.ps1`.

## English

Two ways, nothing to install: paste `sbid-autofill.js` into the browser console on a logged-in sBID session for a one-off fill with a settings panel, or use the `windows/` PowerShell version (built into Windows) that logs in with credentials stored in a local `config.ps1` and fills pending days and reports every time the PC starts. Both start in simulation mode (`-DryRun` / panel checkbox), and both stop as soon as the server does not accept a save. Only log hours you actually worked.

## Licencia

MIT
