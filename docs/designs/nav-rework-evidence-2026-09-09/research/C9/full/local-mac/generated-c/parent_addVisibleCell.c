static N_INLINE(void, addVisibleCell__OOZsrcZshellZbody95nav_u2045)(tyObject_BodyNavSeatcolonObjectType___0c87LTWzqtz7zmat1zT0Kw* seat_p0, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ origin_p1, NF32* kernel_p2, NI kernel_p2Len_0, NI kernelRadius_p3, NI gx_p4, NI gy_p5) {
	NI index_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_270;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_271;
	NI diameter_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_272;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_273;
	NI kernelX_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_274;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_275;
	NI kernelY_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_276;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_277;
	NI kernelIndex_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_278;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_279;
	NI word_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_280;
	nimfr_("addVisibleCell", "body_nav.nim");
{	{
		NIM_BOOL T3_;
		NIM_BOOL T4_;
		NIM_BOOL T5_;
		T3_ = (NIM_BOOL)0;
		T4_ = (NIM_BOOL)0;
		T5_ = (NIM_BOOL)0;
		T5_ = (gx_p4 < ((NI)0));
		if (T5_) goto LA6_;
		T5_ = ((*seat_p0).danger.gridW <= gx_p4);
LA6_: ;
		T4_ = T5_;
		if (T4_) goto LA7_;
		T4_ = (gy_p5 < ((NI)0));
LA7_: ;
		T3_ = T4_;
		if (T3_) goto LA8_;
		T3_ = ((*seat_p0).danger.gridH <= gy_p5);
LA8_: ;
		if (!T3_) goto LA9_;
		goto BeforeRet_;
	}
LA9_: ;
	if (nimMulInt(gy_p5, (*seat_p0).danger.gridW, &TM__fw0EGWK0CbR9aJ84zaF6cBg_270)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_270), gx_p4, &TM__fw0EGWK0CbR9aJ84zaF6cBg_271)) { raiseOverflow(); goto BeforeRet_;
	};
	index_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_271);
	{
		if (index_1 < 0 || index_1 >= (*seat_p0).dangerWorkspace.visited.len){ raiseIndexError2(index_1,(*seat_p0).dangerWorkspace.visited.len-1); goto BeforeRet_;
		}
		if (!((*seat_p0).dangerWorkspace.visited.p->data[index_1] == (*seat_p0).dangerWorkspace.visitGeneration)) goto LA13_;
		goto BeforeRet_;
	}
LA13_: ;
	if (index_1 < 0 || index_1 >= (*seat_p0).dangerWorkspace.visited.len){ raiseIndexError2(index_1,(*seat_p0).dangerWorkspace.visited.len-1); goto BeforeRet_;
	}
	(*seat_p0).dangerWorkspace.visited.p->data[index_1] = (*seat_p0).dangerWorkspace.visitGeneration;
	if (nimMulInt(kernelRadius_p3, ((NI)2), &TM__fw0EGWK0CbR9aJ84zaF6cBg_272)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_272), ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_273)) { raiseOverflow(); goto BeforeRet_;
	};
	diameter_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_273);
	if (nimSubInt(gx_p4, origin_p1.Field0, &TM__fw0EGWK0CbR9aJ84zaF6cBg_274)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_274), kernelRadius_p3, &TM__fw0EGWK0CbR9aJ84zaF6cBg_275)) { raiseOverflow(); goto BeforeRet_;
	};
	kernelX_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_275);
	if (nimSubInt(gy_p5, origin_p1.Field1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_276)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_276), kernelRadius_p3, &TM__fw0EGWK0CbR9aJ84zaF6cBg_277)) { raiseOverflow(); goto BeforeRet_;
	};
	kernelY_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_277);
	if (nimMulInt(kernelY_1, diameter_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_278)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_278), kernelX_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_279)) { raiseOverflow(); goto BeforeRet_;
	};
	kernelIndex_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_279);
	if (nimAddInt((*seat_p0).dangerRecordBase, (NI)((NI64)(kernelIndex_1) >> (NU64)(((NI)6))), &TM__fw0EGWK0CbR9aJ84zaF6cBg_280)) { raiseOverflow(); goto BeforeRet_;
	};
	word_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_280);
	if (word_1 < 0 || word_1 >= (*(*seat_p0).dangerSourceCache).bits.len){ raiseIndexError2(word_1,(*(*seat_p0).dangerSourceCache).bits.len-1); goto BeforeRet_;
	}
	if (word_1 < 0 || word_1 >= (*(*seat_p0).dangerSourceCache).bits.len){ raiseIndexError2(word_1,(*(*seat_p0).dangerSourceCache).bits.len-1); goto BeforeRet_;
	}
	(*(*seat_p0).dangerSourceCache).bits.p->data[word_1] = (NU64)((*(*seat_p0).dangerSourceCache).bits.p->data[word_1] | (NU64)((NU64)(1ULL) << (NU64)((NI)(kernelIndex_1 & ((NI)63)))));
	if (index_1 < 0 || index_1 >= (*seat_p0).danger.values.len){ raiseIndexError2(index_1,(*seat_p0).danger.values.len-1); goto BeforeRet_;
	}
	if (kernelIndex_1 < 0 || kernelIndex_1 >= kernel_p2Len_0){ raiseIndexError2(kernelIndex_1,kernel_p2Len_0-1); goto BeforeRet_;
	}
	pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[index_1]), kernel_p2[kernelIndex_1]);
	}BeforeRet_: ;
	popFrame();
}