FROM perl:5.38

# Системные зависимости
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Установка cpanm
RUN cpan App::cpanminus

WORKDIR /app

# Сначала зависимости (для кэша Docker)
COPY cpanfile /app/
RUN cpanm --notest --installdeps .

# Потом код
COPY . /app

EXPOSE 5000

CMD ["plackup", "-s", "Starman", "-l", "0.0.0.0:5000", "events.psgi"]
