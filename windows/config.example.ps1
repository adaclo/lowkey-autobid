# Copia este fichero como config.ps1 (en esta misma carpeta) y rellenalo.
# config.ps1 NO se sube a GitHub (.gitignore): contiene tu contrasenya.

$Config = @{
    Username = 'TU_USUARIO_SBID'
    Password = 'TU_CONTRASENYA_SBID'

    HoursPerDay = 4          # horas por dia (si sBID permite menos, usa el maximo permitido)
    MinBlock    = 0.5        # minimo de horas por actividad
    MinActs     = 2          # actividades distintas por dia (minimo)
    MaxActs     = 3          # actividades distintas por dia (maximo)
    Seed        = 'cambia-esto'   # mismo valor = mismo reparto

    # Codigo de actividad = peso. Mas peso = mas horas de media. Las que no pongas no se usan.
    Activities = @{
        '1.3' = 1; '1.4' = 2; '1.5' = 3
        '2.3' = 2; '2.4' = 3; '2.5' = 2; '2.8' = 2
        '4.3' = 1; '4.6' = 1
    }

    SkipWeekends   = $true
    SkipDates      = @('2026-12-25', '2026-12-26')   # vacaciones, bajas, festivos (AAAA-MM-DD)
    FillTodayAfter = '18:00'    # el dia de hoy solo se rellena si el PC arranca despues de esta hora ('' = nunca)
    FillReports    = $true      # informes periodicos
    Rating         = 'auto'     # 'auto' = la valoracion mas alta
    MaxPerRun      = 60         # tope de tareas por ejecucion
    Notify         = 'changes'  # notificaciones de Windows (solo sin panel): 'changes' | 'errors' | 'all' | 'none'

    UiCloseSeconds      = 6     # el panel se cierra solo X segundos despues de terminar bien
    UiErrorCloseSeconds = 60    # ...y X segundos si algo falla o se para (cualquier tecla lo cierra)
}
