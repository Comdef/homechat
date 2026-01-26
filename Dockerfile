FROM perl:5.38

RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN curl -L https://cpanmin.us | perl - App::cpanminus

COPY cpanfile /app/
RUN cpanm --notest --installdeps .

COPY . /app

EXPOSE 5000

CMD ["starman", "--workers", "2", "--port", "5000", "main.psgi"]

