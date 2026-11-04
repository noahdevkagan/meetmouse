"""Spanish pages, rendered by site/build.py with render_es.

Not a translated site: one page per Spanish search we already show up for,
written for the reader, with the same verified prices and facts as its English
twin (keep them in sync; prices in USD). Each page links its English version
and both carry hreflang alternates. The app itself is English only, and the
page says so.
"""

ES_PAGES = [
    {
        "slug": "es/alternativas-a-fathom",
        "en": "/blog/fathom-alternatives",
        "title": "Las 5 mejores alternativas a Fathom en 2026 (con precios)",
        "description": "Las mejores alternativas a Fathom, con precios reales y límites de los planes gratis: MeetMouse, Granola, Otter, tl;dv y Fireflies. Cuál conviene según lo que buscas.",
        "h1": "Las 5 mejores alternativas a Fathom en 2026",
        "label": "Alternativas a Fathom",
        "checked": "20 de octubre de 2026",
        "dek": (
            "Aclaración: yo hago MeetMouse, así que aparece primero. Fathom es el mejor grabador de reuniones "
            "gratis que existe. La gente lo deja por tres razones: un bot de Fathom entra a cada llamada por "
            "defecto, todas las grabaciones quedan en sus servidores, o meses de resúmenes perfectos nunca "
            "hicieron que nadie mejorara en sus reuniones. Cada herramienta de abajo dice en qué nos gana."
        ),
        "quick": (
            "<strong>MeetMouse</strong> es la mejor alternativa a Fathom si no quieres un bot en la llamada ni "
            "tus reuniones en la nube de nadie: gratis para 3 reuniones por semana, en tu Mac. Elige "
            "<strong>Granola</strong> si lo único que te molesta es el bot, <strong>Otter</strong> si quieres "
            "buscar en meses de transcripciones, y <strong>Fireflies</strong> si en realidad eres un equipo de ventas."
        ),
        "app_note": "Un detalle: los menús de MeetMouse están en inglés por ahora. Las reuniones en español se transcriben bien y las notas salen en español. En reuniones que no son en inglés, el coaching en vivo se limita a lo que funciona en cualquier idioma, como cuánto tiempo llevas hablando.",
        "tools": [
            {
                "key": "meetmouse", "name": "MeetMouse", "mine": True,
                "best": "Coaching en vivo y privado, en Mac",
                "price": "Gratis para 3 reuniones por semana. Ilimitado por $20 USD, un solo pago. Sin suscripción ni cuenta.",
                "free": "Primera semana ilimitada, luego 3 reuniones por semana; tus notas nunca se bloquean",
                "bot": "No", "audio": "Se queda en tu Mac",
                "review": (
                    "Hice MeetMouse porque años de transcripciones nunca me hicieron mejor en las reuniones. "
                    "Escucha desde tu Mac, muestra la transcripción en vivo y cuánto habla cada quien, y te da "
                    "avisos durante la llamada, por ejemplo cuando llevas mucho rato hablando. En reuniones en "
                    "inglés también te avisa cuando hiciste tres preguntas juntas o cuando un compromiso se quedó "
                    "sin fecha. La transcripción y la IA corren en tu Mac "
                    "por defecto y funciona sin WiFi."
                ),
                "good": ["Sin bot, sin cuenta, funciona sin internet",
                         "Avisos durante la llamada, ocultos al compartir pantalla",
                         "Gratis para empezar; ilimitado por $20 USD una sola vez"],
                "bad": ["Solo Mac (macOS 14.2 o posterior)",
                        "Sin sincronización con CRM ni panel para equipos",
                        "Los menús están en inglés, y en reuniones en español el coaching en vivo es más limitado",
                        "Si activas Claude u OpenAI en Ajustes, el texto va a ese proveedor (el audio nunca)"],
                "url": "/",
            },
            {
                "key": "granola", "name": "Granola",
                "best": "Notas sin bot en la llamada",
                "price": "Gratis con 30 días de historial. Business $14 USD por usuario al mes.",
                "free": "Reuniones ilimitadas, 30 días de historial",
                "bot": "No", "audio": "IA en la nube para las notas",
                "review": (
                    "Granola captura el audio del sistema en tu Mac, así que nadie llamado Granola entra a la "
                    "llamada, y las notas son excelentes. Las escribe con IA en la nube, así que no es la opción "
                    "más privada. Elígela si el problema es el bot."
                ),
                "good": ["Sin bot: captura el audio en tu computadora", "Notas excelentes"],
                "bad": ["Las notas se generan con IA en la nube", "El plan gratis solo guarda 30 días de historial"],
                "url": "https://www.granola.ai",
            },
            {
                "key": "otter", "name": "Otter",
                "best": "Buscar en meses de transcripciones",
                "price": "Gratis 300 minutos al mes. Pro $16.99 USD al mes ($8.33 con pago anual).",
                "free": "300 minutos al mes, máximo 30 minutos por conversación, tus 25 conversaciones más recientes",
                "bot": "Sí, por defecto (su app de escritorio puede grabar sin bot)", "audio": "Su nube",
                "review": (
                    "Otter lleva más tiempo que nadie transcribiendo reuniones, y su búsqueda en meses de "
                    "transcripciones es muy buena. El plan gratis alcanza para más o menos una semana de "
                    "reuniones reales. Elígelo si lo importante es el archivo."
                ),
                "good": ["Muy buena búsqueda en reuniones pasadas", "Apps para iPhone y Android"],
                "bad": ["El plan gratis se corta a los 30 minutos por conversación", "El audio se procesa en su nube"],
                "url": "https://otter.ai",
            },
            {
                "key": "tldv", "name": "tl;dv",
                "best": "Compartir fragmentos con tu equipo",
                "price": "Gratis con grabaciones ilimitadas y notas de IA en 10 reuniones. Pro $29 USD por usuario al mes ($18 con pago anual).",
                "free": "Grabaciones ilimitadas, notas de IA en 10 reuniones, datos guardados hasta 3 meses",
                "bot": "Sí", "audio": "Su nube",
                "review": (
                    "Si lo que compartes con tu equipo es \"miren estos 40 segundos\", los clips de tl;dv son "
                    "los mejores de la lista. El plan gratis graba sin límite, pero las notas de IA se acaban "
                    "después de 10 reuniones."
                ),
                "good": ["Los mejores clips para compartir", "Graba reuniones ilimitadas gratis"],
                "bad": ["Las notas de IA gratis se acaban a las 10 reuniones", "Un bot entra a la llamada"],
                "url": "https://tldv.io",
            },
            {
                "key": "fireflies", "name": "Fireflies",
                "best": "Equipos de ventas que necesitan CRM",
                "price": "Plan gratis con resúmenes limitados. Pro $18 USD por usuario al mes ($10 con pago anual).",
                "free": "Transcripción ilimitada, resúmenes de IA limitados, 400 minutos de almacenamiento por equipo",
                "bot": "Sí", "audio": "Su nube y tu CRM",
                "review": (
                    "Fireflies es infraestructura para equipos de ventas: graba cada llamada, la califica y la "
                    "manda al CRM. Para una sola persona es demasiado. Elígelo si diriges un equipo comercial."
                ),
                "good": ["Envía las llamadas a tu CRM", "Calificación de llamadas y paneles para gerentes"],
                "bad": ["Demasiado para una persona", "Un bot entra a cada llamada", "Se cobra por usuario"],
                "url": "https://fireflies.ai",
            },
        ],
        "fathom_row": ["Fathom", "Grabaciones, transcripciones y resúmenes ilimitados",
                       "Premium $20 USD al mes ($16 con pago anual)", "Sí, por defecto (sin bot en beta)", "Su nube"],
        "enough": (
            "Si el bot no cambia cómo hablan tus invitados y no te molesta la nube, quédate con Fathom. Su plan "
            "gratis es el más generoso de esta página, y mucha gente usa MeetMouse al mismo tiempo: Fathom para "
            "el registro, MeetMouse para mejorar."
        ),
        "faq": [
            ("¿Hay alguna alternativa a Fathom igual de buena gratis?",
             "Para tomar notas gratis, no. El plan gratis de Granola guarda 30 días de historial, el de Otter se corta en 300 minutos al mes y las notas de IA gratis de tl;dv se acaban a las 10 reuniones. La gente cambia por el bot, por la nube o porque quiere algo más que notas."),
            ("¿Cuáles son los límites del plan gratis de Fathom?",
             "El plan gratis de Fathom graba y transcribe llamadas ilimitadas con resúmenes de IA al instante. Los resúmenes avanzados, las tareas generadas por IA y Ask Fathom requieren Premium: $20 USD al mes ($16 con pago anual). El plan Team cuesta $19 USD por usuario al mes, con mínimo de 2 usuarios, y Business $34. Precios de fathom.ai del 20 de octubre de 2026."),
            ("¿Cuál es la mejor alternativa a Fathom sin bot?",
             "Granola, que captura el audio del sistema en tu Mac, así que nadie entra a la llamada. MeetMouse tampoco usa bot y además deja la transcripción y la IA en tu Mac por defecto. Fathom ya ofrece captura sin bot en beta, así que revisa eso primero si el bot es tu única queja."),
            ("¿Hay una alternativa a Fathom que no guarde las reuniones en la nube?",
             "MeetMouse. La transcripción y la IA corren en tu Mac por defecto y funciona sin WiFi. Todas las demás de esta lista, incluida Granola, usan IA en la nube."),
            ("¿MeetMouse funciona en español?",
             "Sí para transcribir: reconoce el español (y otros 24 idiomas), incluso mezclado con inglés en la misma llamada, y escribe las notas en el idioma de la reunión. Los menús están en inglés, y en reuniones en español el coaching en vivo se limita a avisos que funcionan en cualquier idioma, como el tiempo que hablas. Necesita una Mac con Apple Silicon para idiomas distintos del inglés."),
        ],
    },
]
