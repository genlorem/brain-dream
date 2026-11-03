"""Адаптер офлайн-тестов с собственным runner к pytest."""
import pytest


@pytest.fixture
def tmp(tmp_path):
    return tmp_path
