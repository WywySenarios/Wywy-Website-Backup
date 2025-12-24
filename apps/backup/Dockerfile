FROM python:3.14.0-slim-bookworm

COPY ./apps/backup/requirements.txt .
RUN rm -rf /var/lib/apt/lists/*

RUN pip install -r requirements.txt

RUN useradd -m app
USER app

COPY --chown=app:app ./apps/backup .

EXPOSE 8000

CMD ["python3", "manage.py", "runserver", "0.0.0.0:8000"]