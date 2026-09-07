"""The shared requests-spool writer (#1732).

These assert the property the four duplicated copies existed to maintain, which no test asserted
directly before: the request becomes visible under its final name ATOMICALLY, and the dotted temp
file it was staged through does not survive. The callers' own tests cover what each intent CARRIES;
this covers how it LANDS."""

import json
import os
import stat

import pytest

from mining_dashboard.service import request_spool


@pytest.fixture
def spool(tmp_path, monkeypatch):
    """Patch the attribute on the shared config object, not an import-time binding — the same
    shape every control test uses, and the reason `request_spool` reads it per call."""
    monkeypatch.setattr(request_spool.config, "CONTROL_REQUESTS_DIR", str(tmp_path))
    return tmp_path


class TestWrite:
    def test_lands_under_the_id_as_its_filename(self, spool):
        rid = request_spool.write({"id": "abc", "action": "diag-doctor"})
        assert rid == "abc"
        assert json.loads((spool / "abc.json").read_text()) == {
            "id": "abc",
            "action": "diag-doctor",
        }

    def test_no_temp_file_survives_a_successful_write(self, spool):
        request_spool.write({"id": "abc", "action": "diag-doctor"})
        # The dotted temp is the staging name. A leftover would be read by nothing, but its
        # presence would mean the rename did not happen and the visible file is a second write.
        assert [p.name for p in spool.iterdir()] == ["abc.json"]

    def test_the_visible_name_is_only_ever_created_by_a_rename(self, spool, monkeypatch):
        # THE ATOMICITY PROPERTY, and the reason the cleanup test above is not enough: a direct
        # in-place write leaves exactly ["abc.json"] too, so that test cannot tell the two shapes
        # apart. What distinguishes them is that the name the host runner watches for is only ever
        # brought into existence by a rename, so the runner can never observe a partial request.
        #
        # This matters more now than it did as four copies: one writer means a single future edit
        # removes the property for every intent type at once. Without this assertion that edit
        # leaves the suite green.
        seen = []
        real_replace = os.replace

        def recording_replace(src, dst):
            seen.append(
                (
                    os.path.basename(src),
                    os.path.basename(dst),
                    os.path.exists(dst),
                    stat.S_IMODE(os.stat(src).st_mode),
                )
            )
            return real_replace(src, dst)

        monkeypatch.setattr(os, "replace", recording_replace)
        old_umask = os.umask(0)
        try:
            request_spool.write({"id": "abc", "action": "diag-doctor"})
        finally:
            os.umask(old_umask)
        # The private temp inode becomes the final file by rename, even under a permissive umask.
        assert len(seen) == 1
        tmp, final, existed, mode = seen[0]
        assert tmp.startswith(".abc.") and tmp.endswith(".tmp")
        assert (final, existed, mode) == ("abc.json", False, 0o600)
        assert stat.S_IMODE((spool / final).stat().st_mode) == 0o600

    def test_failed_publication_removes_the_private_temp(self, spool, monkeypatch):
        def fail_replace(_src, _dst):
            raise OSError("replace failed")

        monkeypatch.setattr(os, "replace", fail_replace)
        with pytest.raises(OSError, match="replace failed"):
            request_spool.write({"id": "abc", "action": "diag-doctor"})
        assert list(spool.iterdir()) == []

    def test_failed_publication_preserves_error_when_temp_is_already_gone(self, spool, monkeypatch):
        def remove_then_fail(src, _dst):
            os.unlink(src)
            raise OSError("replace failed after removal")

        monkeypatch.setattr(os, "replace", remove_then_fail)
        with pytest.raises(OSError, match="replace failed after removal"):
            request_spool.write({"id": "abc", "action": "diag-doctor"})
        assert list(spool.iterdir()) == []

    def test_an_unwritable_spool_raises_rather_than_dropping_the_request(self, monkeypatch):
        monkeypatch.setattr(request_spool.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        with pytest.raises(OSError):
            request_spool.write({"id": "abc", "action": "diag-doctor"})

    def test_a_request_without_an_id_raises_before_writing_anything(self, spool):
        # The id is the caller's to mint; this writer must not invent one and must not leave a
        # half-named artefact behind when it is missing.
        with pytest.raises(KeyError):
            request_spool.write({"action": "diag-doctor"})
        assert list(spool.iterdir()) == []
